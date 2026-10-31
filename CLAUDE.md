# CLAUDE.md — durable developer architecture conventions

This file records durable, behavior-grounded architecture decisions
for the Foreman repo. Anything that drifts from these rules without
a tracked TRD is a regression. `AGENTS.md` (the agent-context file)
is read-only here — it's a session-level contract for coding
subagents and remains authoritative for that purpose.

## 1. The agent runtime façade is the only public mutation surface

Callers interact with the runtime **only** through
`ForemanServer.AgentRuntime.execute/3` and `register/1` /
`register_adapter/2`. No other module is allowed to:

- start or stop an invocation
- send a `GenServer.call` directly to `AdapterCatalog` from outside
  the façade
- read `Application.get_env(:foreman_server, :agent_runtime, ...)`
  outside of the supervisor, the façade, `FailurePolicy`, or a
  per-adapter config accessor

Adapters do **not** mutate catalog state. The catalog is the durable
registry of which adapters exist; adapter execution lives in short-
lived `Invocation` processes that the catalog never sees.

## 2. Process layering (agent runtime)

```
ForemanServer.Application
  └── ForemanServer.AgentRuntime.Supervisor         (permanent, :one_for_one)
        ├── ForemanServer.AgentRuntime.AdapterCatalog  (GenServer + Registry)
        └── ForemanServer.AgentRuntime.InvocationSupervisor (DynamicSupervisor)
              └── Invocation                       (temporary — one per execute/3 call)
```

- `AdapterCatalog` is **permanent**: registrations are runtime configuration, not request
  state.
- `InvocationSupervisor` is a `DynamicSupervisor` and is **permanent**.
- `Invocation` children are **temporary** — they never restart. A crashed
  invocation is reported to the façade as `{:error, term()}`; sibling
  invocations and the catalog are unaffected (PRD REQ-002).

Overwatch's worker tree layers the same way, with one restart rule that is
easy to get wrong:

```
ForemanServer.Overwatch                              (permanent, :one_for_one)
  ├── ForemanServer.Overwatch.WorkerRegistry
  ├── ForemanServer.Overwatch.Tracker
  ├── ForemanServer.Overwatch.CrashLoopDetector
  └── ForemanServer.Overwatch.WorkerSupervisor       (DynamicSupervisor)
        └── LaunchWorker                             (transient — one per phase)
```

- `LaunchWorker` children are **transient**, and `LaunchWorker`'s own exit
  reason is the relaunch decision: `:normal`/`:shutdown` from its worker
  (phase finished and reported, or deliberate teardown) exits `:normal` and
  ends the child, while any other worker exit reason becomes
  `{:worker_crashed, reason}` so the child relaunches and
  `CrashLoopDetector` counts the restart.
- Do **not** make them `:permanent`. `:permanent` cannot express "restart on
  crash only", so the supervisor relaunched finished phases too, starting a
  second agent for work that was already over. `RunExecutor`'s detached
  `WorkerSupervisor.stop_worker/2` is cleanup, not a guard — it is a race,
  and in run-de055c18749db5e9c702d24950268cf9 it lost by 56ms and the leaked
  agent ran 8m42s past `RunFailed`, overwriting the run's phase artifact.

## 3. Errors flow one way

Public `:execute/3` always returns one of:

```elixir
{:ok, String.t()}
| {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout}
| {:error, {:non_zero_exit, non_neg_integer()}}
| {:error, :all_backends_failed, %{attempts: [attempt_result()]}}
| {:error, term()}
```

The successful branch **never** contains a backend name. Backend
identity is recorded only in telemetry metadata. Adapter-private
metadata (e.g. raw output tokens) does not leak into the public
result; the adapter may produce it but the invocation returns only
the public text.

## 4. The `BackendAdapter` behaviour

```elixir
@callback name() :: atom()
@callback capabilities() :: %{required(:type) => atom(),
                              required(:strengths) => [...],
                              required(:weaknesses) => [...],
                              required(:supported_contexts) => [...],
                              optional(:cost_per_call) => number(),
                              optional(:typical_latency_ms) => non_neg_integer()}
@callback available?() :: boolean()
@callback execute(%{prompt: String.t(), context: map()}, keyword()) ::
            {:ok, String.t(), map()} | {:error, term()}
```

- `capabilities/0` is validated by `ForemanServer.AgentRuntime.BackendAdapter.validate_capabilities/1`
  at registration time. A missing required field or wrong type returns
  `{:error, reason}` and **nothing is inserted** into the catalog.
- `available?/0` is consulted on every `execute/3` call, not at
  registration time. An unavailable adapter is silently skipped in
  automatic/policy modes but produces `{:error, :backend_unavailable}`
  in manual mode.
- `execute/2` runs inside the `Invocation` process. Adapters are
  responsible for the timeout clock, for any port/process cleanup, and
  for returning a canonical `{:ok, text, metadata}` or
  `{:error, reason}` shape. The invocation adapts that shape into the
  public result types above.

## 5. `execute/3` strategies

```elixir
ForemanServer.AgentRuntime.execute(prompt, context,
  strategy: :manual,        # | :automatic | :policy
  backend: :my_backend,      # required when strategy is :manual
  task_type: :code_review,   # required when strategy is :automatic or :policy
  policy_module: SomeMod,    # only for :policy
  timeout_ms: 60_000,        # per-call override; falls back to FailurePolicy
  fallback: true,            # per-call override; falls back to FailurePolicy
  max_attempts: 3,           # per-call override; falls back to FailurePolicy
  fail_on_unavailable: true # if true (default), no_available_backend is reported
                            # even when fallback is on but no backend is available
)
```

- `:manual` requires `backend`; missing registration returns
  `:backend_not_found`; unavailable registration returns
  `:backend_unavailable`. Manual mode **never** substitutes another
  backend.
- `:automatic` filters `supported_contexts` → `available?/0`, then
  sorts by lower `cost_per_call` (missing values sort last), lower
  `typical_latency_ms` (missing values sort last), and earliest
  registration order. **No random selection.**
- `:policy` calls `policy_module.route(task_type, capabilities)`.
  A non-registered result returns `{:error, :backend_not_found}`.
  An unavailable result is skipped if the resolved failure policy
  has `fallback: true`.

## 5.1 Jido Harness provider and model selection

`ForemanServer.AgentRuntime.JidoHarness` is the supported-provider
source of truth for the Jido Harness adapter. It currently accepts
`:pi` and `:claude` (`@supported_providers`); string provider keys from
decoded workflow context are normalized at this boundary. A LiteLLM
proxy is a model dispatcher reached through one of those providers,
not a provider itself — `:litellm` is not a valid `provider:` value.

Workflow phase `models.default` becomes `context.model`, and
`JidoHarnessAdapter` forwards it as the harness `:model` option for the
selected provider. Provider selection is explicit (`context.provider`);
Foreman must not infer a provider from the model string.

`Workflow.ModelResolution` decides that model once per phase and names the rule:
`:phase_declared` (the phase's `models.default`) > `:project_thread_model` (only for
a phase that declares none) > `:provider_default` (no model passed). `RunExecutor`
logs it per phase launch (`operation: "run_executor.phase_model"`), and every
`PreflightFailure` carries it as `model_source`; both are log/run-state only, with no
event or persisted-shape change. See `docs/user-guide.md` §7.2 for the operator view
and the recovery path.

## 6. `FailurePolicy.resolve/2` precedence

Resolved keys: `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.

`fail_fast` is always `true` in the resolved map (the operator cannot
override it; the literal matches the TRD default verbatim).

Resolution order, high → low:

1. Per-call `opts` — **only present keys override.** `RunExecutor` passes
   `timeout_ms` here when a workflow phase declares `timeout_minutes:`.
2. Per-task app config: `config :foreman_server, :agent_runtime, failure_policies: %{task_type => %{...}}`.
3. App config default: `config :foreman_server, :agent_runtime, default_timeout_ms: ...`.
4. Built-in defaults:
   `%{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: :infinity}`
   (unattended-run-control: dev/prod config sets no `default_timeout_ms`, so
   phases have no default wall-clock deadline; `timeout_minutes: 0` on a
   phase, or omitting it, both resolve to `:infinity` unless an explicit app
   config policy/default is present — declare a positive `timeout_minutes:` to
   opt a phase back into a deadline).

Special rule (TRD-007 AC-3): if the resolved `:fallback` is `true`
and **no layer** supplies `:max_attempts`, then `:max_attempts` is `2`.

## 7. Telemetry contract

A **single** completion event is emitted per `execute/3` call, on
`[:foreman, :agent_runtime, :invocation, :complete]`. The façade owns
this emission (early-exit branches call `emit_early_exit_completion/3`;
the invocation's terminal branch emits the normal-completion event).
Duplicate emissions are a contract violation.

Measurements:

```elixir
%{duration_us: non_neg_integer(), attempt_count: non_neg_integer()}
```

Metadata (a stable whitelist — this is the **only** shape emitted):

```elixir
%{
  status: :ok | :no_available_backend | :backend_not_found
        | :backend_unavailable | :direct_error | :all_backends_failed
        | :policy_module_raised | :invocation_start_failed
        | :timeout | {:non_zero_exit, non_neg_integer()},
  task_type: atom() | nil,
  attempted_backends: [atom()],
  final_backend: atom() | nil,
  successful_backend: atom() | nil,
  adapter_metadata: map()   # adapter-private; never the prompt
}
```

Privacy-safe by construction: every metadata key is constructed by a
narrow clause that pattern-matches the result shape and **projects**
the whitelist — adapters cannot accidentally leak prompt text,
secrets, or full output bodies through metadata. Adapter `metadata`
from a successful adapter is forwarded as `:adapter_metadata`; this
is the only adapter contribution to the completion event.

## 8. Configuration keys (operator-visible)

App config read by the runtime:

| Key | Where read | Default |
|---|---|---|
| `:foreman_server, :agent_runtime, :enabled` | `Application.start/2` child wiring | `false` (set to `true` in `config.exs`) |
| `:foreman_server, :agent_runtime, :adapters` | `AgentRuntime.Supervisor.init/1` | `[]` |
| `:foreman_server, :agent_runtime, :failure_policies` | `FailurePolicy.resolve/2` | `%{}` |
| `:foreman_server, :agent_runtime, :default_timeout_ms` | `FailurePolicy.resolve/2` | `:infinity` |

The per-`task_type` policy map uses the same shape as the resolved
`FailurePolicy.t/0` minus `:fail_fast`:

```elixir
config :foreman_server, :agent_runtime,
  failure_policies: %{
    code_review: %{fallback: true},
    long_running: %{timeout_ms: 5 * 60_000, max_attempts: 3, fallback: true}
  }
```

Adding a key not listed above is treated as a feature request, not
a bug; do not invent behavior for undocumented keys.

## 9. Adapter extension checklist (developer workflow)

1. `defmodule MyApp.MyAdapter do` with `use ForemanServer.AgentRuntime.BackendAdapter`
   (or implement the four callbacks by hand).
2. Implement `name/0`, `capabilities/0`, `available?/0`, `execute/2`.
3. Register via config (`adapters: [...]`) or at boot:
   `ForemanServer.AgentRuntime.register(MyAdapter)`.
4. Validation runs on every registration; fix any
   `{:error, reason}` reply before considering the adapter wired.
5. ExUnit coverage:
   - adapter returns `{:ok, text, %{}}` for the happy path,
   - adapter returns `{:error, reason}` for the canonical failure,
   - `available?/0` is `false` when the underlying resource is gone,
   - the public `execute/3` result contains **no** backend identifier.

## 10. Things that are deliberately not in this slice

- No streaming. Each `execute/3` is one round-trip; partial progress
  is not surfaced.
- No retry of the entire execution across crashes. The invocation
  process owns attempt history; the OS process backing a crashed
  adapter may leak a temp file.
- No queueing for unavailable adapters. An empty / unavailable
  catalog returns `:no_available_backend` immediately.
- No remote backend in this slice. `JidoHarnessAdapter` runs provider CLIs locally.

These are tracked in the TRD-2026-6af02293 documentation under
*Open Issues / Future Work*. Any code that introduces them inline
without a TRD is out of scope.

## 11. Workflow catalog is the only manifest source (Go/Elixir CQRS slice)

`ForemanServer.Workflow.Catalog` is the supervised GenServer that owns
every parsed workflow manifest and prompt body in memory and keeps
them in sync with the on-disk root (`~/.foreman/workflows` by default,
overridable via `config :foreman_server, :workflow_root` —
`AssetCatalog.default/0` reads that key before falling back to
`~/.foreman/workflows`; the test suite points it at a repo-local
fixture catalog so it never depends on an operator's real directory).
Phase specs normalize `commit:` and
`stack_pr:` as boolean phase fields and `timeout_minutes:` (or camelCase `timeoutMinutes:`) as an optional
non-negative-integer phase execution timeout in minutes (`0`, or omitting the
key entirely, means no timeout — see §6). `stack_pr: true` records a
phase PR from the single run branch to the recorded run base branch and keeps it
separate from the final run `pr_url`; PhasePR must push the head before open-PR
reuse so a record cannot mask a stale provider diff.

- **Single owner of manifests.** `Approval.resolve_workflow_snapshot/2`
  (the public `Approval.prepare/2` path) and the private
  `RunExecutor.read_phase_prompt/2` read through the catalog.
  No module reads a workflow manifest or prompt file directly;
  the catalog is the only path.
- **Auto-install is gated.** `init/1` calls
  `ForemanServer.WorkflowTemplate.Installer` only when the root
  contains no `*.yaml` manifests. A populated `prompts/` directory
  does **not** suppress the install; the installer uses
  `File.cp/2`/`File.write/2` and will overwrite any same-named
  prompt already on disk. Keep custom templates under their own
  filenames.
- **Synchronous load.** Every manifest is parsed via
  `ForemanServer.Workflow.Interpreter.load/1` and every prompt via
  `File.read/1` during `init/1` so the first command after boot
  finds the catalog ready.
- **Hot reload by polling.** A periodic timer (default 2 s,
  override via `Application.put_env(:foreman_server,
  :workflow_catalog_poll_ms, ms)`) re-hashes every entry and
  replaces any whose content or mtime changed; vanished files are
  removed. `:fs` is **not** used; this slice does not depend on
  the `FileSystem` package.
- **Test isolation.** `Catalog.server/0` reads the
  `:workflow_catalog` app env so tests can redirect to a scoped
  instance via `Application.put_env(:foreman_server,
  :workflow_catalog, server_name)` without tearing down the
  app-managed catalog.

Telemetry: `[:foreman_server, :workflow, :installed]`,
`[:foreman_server, :workflow, :manifest, :loaded | :reload, :ok |
:reload, :error | :removed]`,
`[:foreman_server, :workflow, :prompt, :loaded | :reload, :ok |
:reload, :error | :removed]`.

Skills boot-install emits `[:foreman_server, :skills, :installed]`
(`%{count: files_copied}` / `%{paths: [...]}`) and
`[:foreman_server, :skills, :install, :error]` (`%{reason: term()}`);
the result is never discarded (§5.2). `Skills.Installer.maybe_install/1`
copies only the bundled skills missing from `~/.foreman/skills`, so a
skill added to the bundle in a later release reaches an operator who
already has one installed without clobbering their edits.

Operator-facing CLI: `foreman workflow install --target PATH [--source PATH | --remote URL]`
(see `docs/cli-reference.md`). The CLI is a thin shell around the
HTTP admin endpoint and is **not** an alternate write path to the
event store; it only materialises assets on disk.

## 12. Foreman-managed worktree contract for implement-trd workflows (Go/Elixir CQRS slice)

Foreman bundles two workflow manifests at
`packages/foreman_server/priv/defaults/workflows/`:
`implement-trd.yaml` and `implement-trd-beads.yaml`. Both declare
the worktree schema, register with
`ForemanServer.WorkflowTemplate.Installer` (`@template_names`), and
are deployed by `foreman init --force`. The CLI selects them via
`--workflow-type implement-trd` or `--workflow-type implement-trd-beads`
(see `docs/cli-reference.md` for the full flag set).

`implement-trd-beads` no longer implements a TRD in one skill call: its single
phase dispatches `/skill:ensemble-beads-build {{implementation.bead_id}}
--foreman` (formerly `/skill:ensemble-full-implement-trd-beads
{{implementation.trd_path_argument}} --foreman`), where `bead_id` is the
frozen id of the tagged root epic bead (`task.external_id`), and it declares no
`timeout_minutes:` (no deadline). The run is judged on the Beads graph, not the
agent: after the last phase's commit `RunExecutor.verify_run_outcome/2`
(`Workflow.BeadsTreeCompletion`) fails the run unless every parent-child
descendant of the epic is `closed` (`:incomplete_children`,
`:beads_tree_unreadable`, `:beads_tree_unverifiable`). The same hook runs
`Workflow.CheckoutGuard` first (foreman-koas6): an empty run branch while the main checkout
gained files fails the run with `:checkout_written_instead_of_worktree`. A worktree cleanup
refuses (dirty) is recorded as `RunWorktreeRetained` (`run.worktree_retained`, foreman-gr27) on the
run projection's `retained_worktrees`. Mechanics and caveats:
`docs/lessons/beads-runtime-and-dispatch.md`; operator view: `docs/user-guide.md`
("Executing a Beads epic tree").

Strict approval rendering materializes the `command` field and the
`worktree.base` field so the human review surfaces the exact slash
command and base ref Foreman will execute. Branch placeholders
(`{task_id}`, `{run_id}`) and the path placeholders (`{task_id}`, `{run_id}`) remain
runtime-resolved; `{phase}` is retained only as literal text, not substituted.

The phase runner (`ForemanServer.Workflow.RunExecutor`) auto-injects
the following env vars when the worktree is enabled:
`FOREMAN_WORKTREE`, `FOREMAN_RUN_ID`, `FOREMAN_WORKTREE_PATH`,
`FOREMAN_EXPECTED_BRANCH`, `FOREMAN_SOURCE_REVISION`, and
`FOREMAN_IMPLEMENTATION_KEY`. The Beads-backed flow additionally
receives `BEADS_DB` and `TRD_SCOPE` when the planning context
provides them. `FOREMAN_EXPECTED_BASE` is **not** injected; the base
is resolved lazily at completion time to honor pushes that landed
during the phase.

**Project environment (E4).** `ForemanServer.ProjectEnvironment.resolve/2` is the
single producer of a project's agent env and redaction list; `RunExecutor`,
`Overwatch` and `Jobsite.Executor` all call it, never `config.env` directly.
`ProjectEnvironment.secrets/1` is that redaction list on its own: every secret-store
VALUE of 8 or more characters (whatever its name; `ProjectEnvironment.min_stored_secret_chars/0`, shorter ones would rewrite prose) plus the values of pattern-named env vars at any length. Project memory
(topic content, description/index, hand-edit sync), coordinator conversation text
(`Coordinator.Redact.text/3`), standing context (`ProjectContext`), the operator question
text (`OperatorQuestionDispatcher`), the tool-call input summary (`Approvals.Requester`), thread
transcripts (`Threads.Transcript`, at read time), the PR-fix prompt (`PrFix`) and a coordinator
turn's recorded actions and failure messages (`Coordinator.Commands`) redact with it by value.
ONE path: `Coordinator.Redact`. Resolve the list ONCE per document/batch/command
(`Redact.secrets/1`, or `Redact.redactor/1` for many texts), never per entry. The persist and
read paths of those system actors never raise: no project id (a global or legacy run) or a
project whose environment `resolve/2` refuses is redacted by the built-in patterns only, with
a warning naming the project id and error code (never a name or value); `Redact.text/3` and
`data/3` WITHOUT an explicit `:secrets` list keep `secrets/1`'s strict contract (a refused
environment raises). Known limits: a shared FRAGMENT between two secrets (a suffix of one is a
prefix of another) cannot be fixed by ordering, so the guarantee is that no listed value appears
verbatim (`WorkerLogPolicy.redact/2` replaces the longest value first, whatever the caller's list order); `PrFixRequested` events stored before PR #761 are not rewritten (the operator's note is value-redacted in `CommandGateway` now, and `TurnRunner`'s failed-turn and action-reason log lines are redacted before they are cut); an unreadable secret store degrades redaction to the other values; redaction can lengthen a note near the 2000-character cap into `invalid_note`. Observed live 2026-10-30 (`scripts/e2e/redaction_value_live.sh`, `foreman-mw5rz`, fixed by PR #775 and re-verified live 2026-10-31): the server's debug request log (Phoenix `Parameters:` and LiveView `HANDLE EVENT` lines, stdout and `foreman-server.log`) carried the arguments of an MCP `tools/call` and the text of a chat request before redaction; `config :phoenix, :filter_parameters` now hides the free-text keys, the MCP `params` envelope and `token` by key name (a free-text key added later is not covered until it is listed; the fail-closed follow-up is `foreman-25sqf.1.1`); every other durable surface searched was clean (`docs/acceptance/e2e-live-verify-2026-10-30.md`). New text
persisted about a project MUST use `secrets/1` (through `Coordinator.Redact`), not
`WorkerLogPolicy.redact/1` alone.
Secret VALUES live only in `ForemanServer.SecretStore` (file backend, dir from
`config :foreman_server, :secret_store, dir:`; tests point it at a tmp dir) and
must never enter an event, command payload, log, projection or API response:
`ProjectSecrets.set/4` stores the value then dispatches the system-only
`project.secret.set` carrying name+version. `config.environment` (vars,
`setup_script`, network) is written only by the operator command
`project.environment.set`; `project.update`/`register` reject the key. The setup
script (`ProjectSetup`, run via `Jobsite.HostCommand` in its own process group)
runs once after worktree creation on both doors; network policy
(`Jobsite.NetworkPolicy`) is enforced on docker jobsites only.

**Project repositories (E12, design `docs/spikes/S3.md`).** A project's `path` is
its PRIMARY repository; further repositories are the `ProjectRepositoryAdded` /
`ProjectRepositoryRemoved` events on `project:<id>` (`project.repo.add|remove` in
`Aggregates.Project`: pure checks only — id `^[a-z0-9][a-z0-9-]{0,31}$`, `"main"`
reserved, absolute unique paths, `task_provider` reserved nil). There is no event
for the primary: `ProjectionStore.project_repositories/1` synthesises
`%{id: "main", path: path, default_branch: nil, primary: true, ...}` at READ time,
so legacy projects need no backfill and a `project.update` path change moves it
(`default_branch` is nil = "branch checked out at run start", never `"main"`).
Impure checks (realpath, git work tree, same-`origin` duplicate) live in
`Projects.RepoValidation.check_candidate/3` and belong in the CommandGateway
side-effect step before dispatch — for `project.repo.add` AND `project.update`
with a new `path` (`replacing: "main"`). Replay rule: `repo_id` on worktree/PR
events is absent for a run's primary repo (`Workflow.Worktree.operation_id/2`
keeps `wt-<run_id>`), and any key written to a strictly decoded event must be a
declared struct field in the same commit as its writer.

**One worktree per repository per run (E12-S3).** A run's repo set comes from the
task/run request (`repo_id` = the run's PRIMARY, default the project primary;
`repo_ids` = extra repos) and is resolved at kickoff by `Workflow.RunRepoSet`:
no duplicates, none equal to the effective primary, every id registered
(`{:unknown_repo, id}`), primary + extras <= `max_repos_per_run` (default 4).
A request naming no repo is the single-repo run and reads nothing. The run-start
gate `config :foreman_server, :multi_repo, runs: true` (the default since E12-S12)
admits multi-repo runs; `runs: false` is the operator kill switch and rejects (typed
`{:run_repo_set_rejected, :multi_repo_runs_disabled}`, like other start failures)
any resolved set > 1 OR a run primary that is not the project primary; tests state
the gate they need with `ForemanServer.MultiRepoRuns.enable!/0` / `disable!/0`. Layout/branch/op-id
arithmetic is `Workflow.RunWorktreeLayout` (primary `<run>/workspace`, secondary
`<run>/repos/<repo_id>`, one branch name in every repo); secondaries are created
eagerly after the primary with `repo_id` on their events and rolled back (worktree
and branch, primary included) on failure as `{:multi_repo_worktree_failed, id,
reason}`. `state.run_worktrees` (repo id => record, rebuilt from the run's
worktree projection each phase and on resume) holds every repo; `run_worktree`
stays the primary alias. Every run worktree is committed at phase end
(`phase_finish/5`) and on pause, and cleaned at terminal (continue-on-error).
`RunExecutor.repo_root/2` refuses ids not registered on the run's project.

**Repo targeting, thread repo requests and fan-out (E12-S9..S11).** `task.create`
(and the MCP `foreman_task_create`, the retired `work.submit` ergonomics) accepts
optional `repo_id` (the run's PRIMARY) and `repo_ids` (extras); the Task aggregate
validates them through `Workflow.RunRepoSet.resolve/3` BEFORE `TaskCreated` is
written (`{:unknown_repo, id}`, duplicates, extra equal to the primary, then the
`max_repos_per_run` cap counting primary + extras) and writes the keys only when
present (a `repo_id` equal to the project primary is dropped: absent == project
primary). The executor reads them from the task projection. Provider resolution is
unchanged (one provider per project; BeadSink attributes only). A secondary-primary
run is a multi-repo run like any other and is admitted while the gate is open.
`run.repo.request {run_id, repo_id | repo_path}` is a SYSTEM command
(`CommandGateway.dispatch_system/2` -> `Workflow.RunRepoRequest`, NOT in the
operator allowlist): realpath first, then `repo_allowlist` (`/`-bounded prefixes,
empty = off, applies to registered repos too; `repo_allowlist` and `max_repos_per_run` are operator-only containment: `foreman project update --repo-allowlist/--max-repos-per-run` and the workspace form, deliberately NOT keys of MCP `foreman_project_settings_update`), already-attached returns success
BEFORE the cap, then `max_repos_per_run` (primary + extras), then for an
unregistered path git-work-tree + remote-duplicate checks and a system
`project.repo.add` (`added_by: "run:<id>"`, command id
`run-repo-add:<run>:<sha256(path)[0,12]>`), then `Workflow.RepoAttach` creates the
worktree (`wt-<run>-<repo>`); the executor sees it from the NEXT phase because it
rebuilds `run_worktrees` from the worktree projection each phase. Every outcome
appends `RunRepoRequested` to `run_repo_audit:<run_id>` (`Aggregates.RunRepoAudit`,
command `run.repo.audit.record`, command id `run-repo-audit:<request command id>`).
`task.fanout {project_id, title, prompt, workflow_name, repo_ids | "all",
fanout_id?}` (`Workflow.TaskFanout`, system-only) loops `task.create` with task ids
`<fanout_id>-<repo_id>`; rejections are reported per repo and keep earlier tasks. The
MCP write tools `foreman_run_request_repo` and `foreman_task_fanout`
(`MCP.RepoTools`, in `MCP.Policy` `@write_tools`) are the only entry points.

**Env, isolation and prompt contract of a multi-repo run (E12-S4).** Whenever a
phase has a worktree (single-repo runs too) `RunExecutor.foreman_env/4` adds
`FOREMAN_PRIMARY_REPO` (primary repo id, `main` for legacy projects),
`FOREMAN_REPOS` (compact JSON, keys sorted at both levels:
`{"<id>":{"base_branch","base_ref","branch","path","primary"}}`) and
`FOREMAN_REPO_<ID>_WORKTREE` per repo (id upper-cased, `-` -> `_`), recomputed
each phase from the worktree projections. The older `FOREMAN_*` vars keep
describing the primary only. Project `config.env` can never carry any
`FOREMAN_*` name (`ProjectEnvironment` refuses it; the executor merges its own
env last). `VfsIsolation.bind/2` takes a list of roots (a single path is
`[p]`), the executor binds ALL of a run's worktrees in one call per phase (a
re-bind replaces), and roots are `realpath`-canonicalised at bind and the
candidate at check with a `/` boundary, so `..` and symlink escapes are denied.
`add_dirs` (the other worktrees) is passed to the harness only when the
provider's adapter declares `add_dirs` (claude yes; `pi` NO - the resolver
rejects the whole request), so a pi agent works on the other repos through the
absolute paths in `FOREMAN_REPOS` / the `repositories` prompt assign (JSON list
of `{"id","path","branch","primary"}`, with `repositories_count`; both are
strings like every other assign).

**One PR per touched repository (E12-S5, S3 §7).** `RunExecutor.finalize_repo_prs/1`
runs after `maybe_complete_task` and before worktree cleanup: the primary through
the unchanged executor-state path (single-repo runs: same events, command ids, one
association), then every other run worktree through `Workflow.RepoPr.finalize/2`,
which builds its context from projections (`Workflow.RepoPrContext.build/2`: repo
project root = AutoPR cwd, worktree branch, `repo_base_branches`, task
title/description). Untouched (no commits ahead of that repo's base) = `:noop`, no
PR, no association. Results `[{repo_id, :noop | {:ok, url} | {:error, reason}}]`
never short-circuit; a failed repo is logged at error (the `RunRepoPrFailed` event
is S6). Per-repo identity, `repo_id` ABSENT == primary: `PrAssociation.stream_id/2`
(`pr_association:<run>` / `pr_association:<run>:<repo_id>`), `PrAssociate.store/3`,
`PrAssociated.repo_id` and the `run.pr.ready` payload carry `repo_id` only for
non-primary, `Identity.run_pr_ready_command_id/2`
(`workflow:<run>:<repo_id>:pr_ready`), merge hold key `run:<run>:<repo_id>`.
Projection: `pr_association/1` and the run `pr_url` stay the primary's; non-primary
associations live in `repo_pr_associations`, listed (primary first) by
`ProjectionStore.pr_associations_for_run/1`, mirrored in `run_repositories/1` and
the run's `pr_urls` map (only present once a non-primary PR exists). `PrFold` and
the Run aggregate's `merge_gate` ignore a `repo_id` event (per-PR gates are S6).
With 2+ PRs, `RepoPr.cross_link/2` appends "Part of multi-repo run <id>" plus the
sibling `owner/repo#n` links via `gh pr edit --body` (best effort, idempotent,
skipped for single-repo). `stack_pr: true` with more than one repo is refused at
run start: `{:error, :stack_pr_unsupported_multi_repo}` (surfaces as
`{:run_repo_set_rejected, ...}`).

`RunExecutor.init/1` parses the persisted `workflow_snapshot` via
`extract_phase_specs/1`, which uses the dual-key pattern
`Map.get(snapshot, :phases) || Map.get(snapshot, "phases")` so the
persisted (JSON-decoded) projection shape is honored. The
renderer in `CommandGateway.enrich_approval_via_workflow/2` writes
back the canonical string-keyed form so the EventStore-bound
`TaskApproved` payload has exactly one entry per field and the
JSON round-trip is lossless.

### Contract checklist for contributors (worktree/TRD slice)

- **Task vs. workflow.** Provider task type is independent of
  implementation workflow. `--workflow-type` selects which bundled
  manifest Foreman resolves at approval. Approval precedence is
  `workflow_type || task_type || default_task_type`; absent fields
  preserve existing behavior.
- **Tracked TRD.** `--trd-path` must be a tracked regular blob in
  the registered project at the frozen source revision.
  `ImplementationContext.build/1` rejects untracked, working-copy,
  directory, symlink, and traversal cases; the frozen relative path
  and SHA persist for idempotent re-approval.
- **Worktree ownership.** Foreman exclusively creates, pins, and
  cleans the worktree at `~/.foreman/worktrees/<project_id>/<task_id>/<run_id>/<path>`.
  Skills under `--foreman` must verify the trusted
  cwd/branch/revision markers and must not create, switch, append,
  or stack branches. There is no skill-owned worktree fallback.
- **Same-TRD single-flight.** `implementation_key = SHA256(project_id
  <> "\0" <> normalized_trd_path)` is reserved through
  `ProjectRunReserved`. Concurrent `run.start` for the same key is
  rejected with `{:implementation_already_active, key, run_id}`
  before any worktree side effect. The key is server-derived and
  cannot be overridden by operator payload or phase YAML context.
- **Beads scope.** For `implement-trd-beads`, freeze
  `task_provider.config.database_path` (from the TaskProvider
  Registry, not cwd discovery; Go CLI project create/update requires
  `--task-provider-database-path` when `--task-provider=beads`) and
  `TRD_SCOPE = <trd-slug>-<first-12-of-key>`
  at approval. Every `br`/`bv` invocation passes `BEADS_DB` and
  `TRD_SCOPE` explicitly. Scaffolds are prefixed `[trd:<TRD_SCOPE>]`.
- **Bead id.** For `implement-trd-beads`, also freeze `bead_id` (the triggering
  bead's `task.external_id`; missing/blank fails approval with
  `{:implementation_context_failed, :bead_id_missing | :bead_id_malformed}`),
  rendered as `{{implementation.bead_id}}`. A `{{implementation.*}}`
  placeholder still unresolved after approval rendering refuses the approval
  with `{:implementation_placeholder_unresolved, [...]}`.
- **Clean-vs-dirty cleanup.** Clean worktrees are removed on
  terminal phases; dirty worktrees are preserved with reason
  `:dirty` / `:active_workers` / `:clean_failed` /
  `:resolve_dispatch_failed` on
  `[:foreman_server, :vcs, :worktree, :orphan_preserved]`. Recovery
  never force-deletes.

## 13. Task-provider boundary reminder (Go/Elixir CQRS slice)

RunExecutor drives claim/complete/fail. Workflow.BootReconciliation
drives orphan-reopen. `set_priority` and `add_dependency` stay at the
adapter boundary until a separate operator surface TRD introduces them.

## 13.1 Operator run dashboard boundary

The run-management dashboard is `GET /dashboard/runs`, guarded by the
existing browser `:require_authenticated` token plug. Keep `/dashboard`
as the separate Jido live dashboard. The run dashboard reads only
`ProjectionStore` projections (runs, phases, tasks, logs, worktrees,
PR associations) through `ForemanServerWeb.OperatorDashboard`; durable
logs come from `ProjectionStore.run_logs/1`, not server `Logger` output.
Run-control buttons dispatch public operator envelopes through
`CommandGateway.dispatch_operator/1`; Stop is `run.pause` with default
reason `operator_pause`, Abandon is `run.remove`, Resume is
`run.resume`, and Reset/Restart is `run.reset`. Code evidence stays
read-only and may use projected worktree/branch/base data only.

The project workspace is `GET /dashboard/projects/:id` (+ `/settings`,
`ForemanServerWeb.ProjectWorkspaceLive` / `ProjectSettingsLive`), same guard.
It adds no mutation path: actions go through `ForemanServerWeb.Workspace.Actions`
(Threads.Actions, CoordinatorAPI, Library add files/folder, replace, remove and read/download,
ProjectSecrets, operator-allowlisted commands) and updates
come from one coalesced `ProjectionStore` subscription (`Workspace.Refresh`),
never a polling timer. It has no merge/approve-PR control. Socket uploads hold the HTTP
route's whole-add cap `upload_max_bytes` themselves (`Workspace.LibraryUpload`), and a
secret's value is write-only there: handed to `ProjectSecrets.set/4`, never assigned,
rendered, logged or put in an event.

Workspace and settings accessibility baseline (E16): `<main id="main">` plus a
skip link, labelled controls, visible `:focus-visible` rings, `aria-live`
status regions (`#notice`, the instructions counter) and `role="alert"` field
errors. Secrets are never rendered, only reference names. The baseline is
enforced by `scripts/e2e/ui-a11y/ui_a11y.mjs` (axe-core: zero serious/critical;
keyboard focus order; zero idle LiveView frames), a LOCAL acceptance command, not
a CI job; see `docs/spikes/E16-SP1.md`. A new workspace/settings control must
keep that script green.

## 14. Beads sync invariants (Go/Elixir CQRS slice)

Atomic `task.create` and bidirectional Beads sync are governed by
these invariants. Drift without a tracked TRD is a regression.

- **Atomic `task.create`.** `Task.create` flows through the `Task`
  aggregate in a four-stage pipeline (`actor.ex`: `do_dispatch/4`):
  (1) `handle_command/2` produces the stage-1 event spec;
  (2) `resolve_enriched_event_spec/3` invokes the project's configured
  `:create` provider (`TaskProvider.Registry.route(:create, ...)` →
  `provider.create/2`) to mint a Bead **before** the append;
  (3) the actor re-decides `handle_command/2` with the Bead ID
  populated as `payload.external_id` on the event spec;
  (4) `append_and_commit/7` performs the append/ack/commit.
  **Provider failure aborts the command entirely**: a `{:error, _}`
  from `provider.create/2` returns `{:error, reason, state}` with no
  append, no event, and no compensation (no Bead was minted to close).
  **Conflict / re-decision failures compensate the Bead**: on the
  bounded retry path, `compensate_for_conflict/3` closes the Bead via
  `BeadsAdapter.complete/3` with the canonical `transition_comment`
  so a successful stage 2 does not strand. The cache entry in
  `state.in_flight_beads` is the single source of truth for "Bead
  minted but not committed"; clearing it after compensation prevents
  double-close on a subsequent retry. (Other append-failure modes
  outside the conflict-retry path are not characterized here.)
- **`external_id` surface contract.** The successful `task.create`
  HTTP response (HTTP 201 with `status: "accepted"`,
  `result: %{events: 1}`) does **not** carry `external_id` —
  `CommandController.serialize/1` returns `%{events: 1}` for
  `{:ok, _events}` and does not enrich the response with the
  persisted event's fields. Operators retrieve the bead linkage by
  reading the task projection (`GET /api/tasks/:id`).
  `foreman task get` is REMOVED (TRD-018, 2026-09-13) — the
  projection is still readable via that HTTP endpoint directly
  (`curl`, or an MCP tool), just not through this CLI command.
  Its `external_id` field is
  populated on the persisted `TaskCreated` event when the
  project's `task_provider` capabilities advertised `:create`.
  Provider failure aborts the command entirely (no event, no
  successful response, no `external_id` surface).

- **Operator-issued ≠ no-Bead.** A `task.create` issued by the
  operator on a project with a configured `:create` provider still
  gets an `external_id`. The presence/absence of `external_id` means
  "Bead linked" vs "Bead not linked", **not** "operator-issued" vs
  "system-issued". The MCP `foreman_task_create` helper requires
`description` for `FOREMAN_TASK_DESCRIPTION`, passes `prompt` separately for
`:prompt`-action phases, and defaults `auto_approve: true`.
- **Beads → Foreman (inbound) is opt-in.** The
  `BeadsWatcherSupervisor` is added to `ForemanServer.Application`
  only when `config :foreman_server, :start_beads_watcher?, true`.
  The watcher dispatches `task.create` for each new Bead it sees in
  the project's JSONL; that `task.create` re-enters the same Actor
  hook path, so a Bead originated by the watcher does **not** cause
  another Bead to be minted (provider skips when the Bead already
  exists).
- **Orphan janitor is opt-in.** `BeadsOrphanJanitorSupervisor` is
  added only when `config :foreman_server, :start_beads_orphan_janitor?,
  true`. The janitor closes stranded issuance (Bead minted but no
  Foreman task landed within the grace window) and stranded execution
  (Foreman task terminal but Bead never closed by `RunExecutor`). Both
  flags are required for production: watcher-only strands execution,
  janitor-only strands inbound issuance.
- **Adapter boundary holds.** `set_priority` and `add_dependency`
  remain adapter callbacks. No operator surface promotes them into
  Foreman commands in this slice.
- **Doctor surface is honest about current scope** — about its *fields*, not
  its existence. `foreman doctor` is not a command: the Go CLI dispatches only
  `project`, `commands`, `task`, `run`, `workflow`, `init`
  (`packages/foreman_cli/cmd/foreman/main.go`), which `README.md:70` and
  `docs/user-guide.md:595` already state. The field list below describes what
  the surface would report, and matches the server-side shape; treat it as a
  spec, not as an operator command.
  `foreman doctor task_provider` reports the fields it actually
  emits per project: `project_id`, `healthy`, `provider_id`,
  `contract_version`, `br_version`, `capabilities`, `sample_ready`,
  `schema_validation_failures`, `janitor_enabled`, `janitor_running`,
  `orphan_backlog`, and (on the unhappy branch) `error`. The
  janitor fields are a CQRS read of the cached snapshot maintained
  by `BeadsOrphanJanitor`'s own scan loop; the doctor MUST NOT
  invoke `BeadsOrphanJanitor.run_scan/2` itself. Operators needing
  finer-grained runtime visibility (per-scan event streams,
  supervisor lifecycle transitions) should rely on the
  `[:foreman_server, :task_provider, :beads, ...]` telemetry events.

## 15. Per-DB Beads lease (Go/Elixir CQRS slice)

SQLite's single-writer protocol cannot tolerate concurrent `br`/`bv`
writers or writers running alongside `bv --robot-plan`. The
`ForemanServer.Aggregates.BeadsDbLease` aggregate is an event-sourced
lock keyed by the configured absolute Beads DB path passed at acquire
time, giving process-local serialization through the Actor mailbox
while surviving Foreman restarts via persisted events. Different DBs
and direct (`foreman run`) workflows remain parallel. Callers must
pass the same absolute path on every dispatch — symlink aliasing
(e.g. `/tmp/...` vs `/private/tmp/...`) is NOT collapsed and will
register separate lease streams.

- **Acquire-or-enqueue.** `lease.acquire` is atomic: if the DB is
  free, the run becomes the holder; if held, the run is enqueued as a
  waiter and admission returns `:queued`.
- **Release-with-promotion.** When the holder releases with waiters,
  the aggregate emits a single `BeadsDbLeaseTransferred` event that
  releases the old holder and promotes the head waiter, so cancellation
  cannot race with promotion. The `Dispatcher` subscribes to this
  event and re-enters `RunAdmission.start/2` for the promoted run.
- **Process-bound holds.** A hold taken for one `br` call
  (`BeadsDbLease.with_lease/4`: `BeadsAdapter`, each `BeadsWatcher` read
  pass, the orphan janitor) carries the server's
  `ForemanServer.Incarnation`. A server killed mid-call strands that hold
  in the event store; the next incarnation takes it over at once
  (`BeadsDbLeaseAcquired`, `provenance: {:reclaimed_stale_holder, …}`)
  instead of queueing behind it until `:lease_timeout`, and
  `BootReconciliation.scan_lease_orphans/0` (every `beads_db_lease:`
  stream in the event store, not only DBs a task points at) releases the
  holds and waiters of other incarnations (foreman-w29up). A hold with no
  incarnation (`RunAdmission`'s whole-run hold) belongs to a run and is
  reclaimed through run liveness only.
- **Dead callers.** The incarnation tag separates VMs, not processes: a
  `with_lease/4` caller killed inside a live server (`Process.exit(pid, :kill)`,
  a supervisor's `:shutdown`, a linked crash) never runs its `after`.
  Every call is therefore watched by a `BeadsDbLease.Keeper` (under
  `BeadsDbLease.KeeperSupervisor`, outside every caller's subtree) that, when
  the caller goes down, dispatches `lease.remove_waiter` then `lease.release`
  for its `run_id` (reason `:caller_down`), so a dead holder frees the lease
  and a dead waiter is dropped, not promoted (foreman-8qge). No TTL: a hold
  whose caller lives is never given up. A late cleanup is a no-op for a lease
  that moved on. `with_lease/4` returns
  `{:error, {:lease_keeper_unavailable, _}}` while the supervisor is down.
- **Terminal fan-out.** The `Dispatcher` dispatches `lease.release`
  and `lease.remove_waiter` on every terminal run event
  (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
  `RunBlocked`). `RunBlocked` is terminal for lease cleanup: a blocked
  run must release its Beads-DB lease so queued peers can be promoted.
- **Fail-closed gating.** `RunAdmission.start/3` reads the lease
  decision before starting the run supervisor. Any uncertainty
  (acquire error, atom state of `:unknown` or `:unexpected`) returns
  `{:error, ...}` and skips dispatch. A `:queued` decision returns
  without starting the supervisor; the dispatcher picks the run up
  again on `BeadsDbLeaseTransferred`.
- **Compensation.** `lease.release` on admission failure is only emitted
  for definitively non-retryable rejections (`{:missing_or_invalid, …}`,
  `{:implementation_already_active, …}`, `{:command_rejected, …}`).
  Compensating transient errors would break retry semantics.
- **Scope limitation (operator responsibility).** The lease serializes
  only admission through Foreman. External `br` writers and
  `bv --robot-plan` invocations launched outside Foreman (e.g. from a
  human shell or unrelated automation) are NOT gated by this lease.
  If you bypass Foreman and write to the same Beads DB concurrently
  with a held lease, SQLite's single-writer model will still observe
  concurrent writers. Operators must observe single-writer discipline
  themselves. The lease exists to prevent two Foreman-dispatched runs
  from racing on the same DB, not to mediate file-system access against
  unrelated processes. The contract test
  `test/foreman_server/workflow/br_bv_lease_concurrency_test.exs`
  verifies the admission contract; cross-process discipline against
  external writers is a separate, operator-owned concern.

## 19. Durable worker run logs and MCP run status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and
`ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event
streams, and keep `foreman_run_get`'s full projection shape distinct. Both carry
`provider_session_id` (latest) and `provider_sessions` (ordered
`{worker_id, provider, model, provider_session_id}` list), folded from the
`WorkerSessionBound` worker event that `JidoHarnessWorker` emits before
`WorkerExited` (`nil` / `[]` when the provider reported none). They also carry
`usage` (a `ForemanServer.Usage`: input/output/cache-read/cache-write/total tokens and
`cost_usd`, each `null` when the provider did not report it), the sum of the
`UsageRecorded` worker events; cross-run rollups arrive with E14.

`foreman_run_get_logs` is backed by `ProjectionStore`, not console `Logger`
output or ad hoc files. Production worker output must enter the system only as
`WorkerProtocol.emit(:worker_stdout | :worker_stderr, ...)` events on
`worker:<run_id>:<worker_id>` streams. The projection returns empty success for
known runs with no captured output and `:run_not_found` for unknown runs; never
substitute `{:ok, []}` for an unknown run. There is deliberately no
store-unavailable failure — the projection is the `ProjectionStore` GenServer's
own state, so for a known run the read cannot fail, and declaring failures that
cannot occur misdescribes the contract. Redact and control-character-normalize
output before event persistence.

`foreman_inbox_get` reads the per-run operator inbox projection; `foreman_inbox_send` is the write-gated MCP progress-note tool. It dispatches public `inbox.send` through `CommandGateway` only when `allow_workflow_writes: true`, requires `run_id` plus a 1-2,000 character body, permits only safe metadata keys (`phase_id`, `worker_id`, `session_id`, `severity`), and must not carry secrets, prompts, large logs, or command output. Inbox progress complements logs/events/activity; it does not replace them. `foreman_task_add_comment` is the sibling write-gated MCP Work Log tool: it takes `run_id`, `workflow_name`, `phase_name`, and `description`, resolves the provider task server-side, writes through `TaskProvider.comment/3`, and must not accept raw provider ids/bodies. Bundled prompts tell agents to continue work if progress or Work Log tools are denied or unavailable. Built-in `prd`/`fix` command phases receive the same guidance via worker `system_prompt`; slash-command prompt bytes stay unchanged.

**stdout and stderr arrive on different `Jido.Harness` events, and this is the
one thing to check when a channel comes back empty.** stdout text rides
`:output_text_delta` / `:output_text_final` / `:command_output_delta` with a
string-keyed `%{"text" => _}` payload. stderr does NOT: the harness turns
`ProcessEvent{type: :stderr}` into `Event{type: :provider_event}` carrying
`%{"stream" => "stderr", "data" => _}` (`adapters/cli_stream.ex:37-38`,
`session/transports/pi_rpc.ex:138-140`). Selecting only the three text types and
then looking for a `"stream"` key on them — which is never there — made
`WorkerStderr` unreachable while every layer above still advertised
stdout/stderr capture. `jido_harness_worker_log_capture_test.exs` pins both
shapes against the dep source so an upgrade cannot silently re-empty the
channel.

**Retention is bounded on two axes, and both are load-bearing.** Entry count
(5,000/run) does not bound memory, because a log line has no intrinsic size
limit and a run may have many workers; bytes (1 MiB/run) does. This is a bound
on the resident READ MODEL and is distinct from `WorkerLogPolicy`'s bound on how
many events are durably WRITTEN — different resources, not a duplicated
boundary. Every eviction is accounted in `omitted_entries` / `omitted_bytes`, so
a truncated read can never present itself as complete.

## Phase stall detection

`stall_detection` is explicit phase metadata, never inferred from phase names. Normalize it through `ForemanServer.Workflow.StallPolicy`; valid scopes are agent/no-output and messaging/no-progress. `RunExecutor` copies normalized policy onto `phase.start`/`PhaseStarted`, `ProjectionStore.stall_candidates/1` is the bounded detector read, and `ForemanServer.StallDetector` persists stalls through `run.report_stall` only. Do not write projection state directly from the detector. Worker heartbeats do not advance phase output activity; stdout/stderr, assistant messages, tool completions, worker start/exit, and phase lifecycle do.

## 20. SigNoz operational-log bridge

`ForemanServer.Observability.OtelLogBridge` installs an additional Erlang
`:logger` handler (never replaces the default console handler) that exports
redacted operational logs to SigNoz over OTLP/HTTP. It is deliberately
separate from the Langfuse LLM-trace path (`jido_otel`/`opentelemetry_exporter`,
§7 above) — different destination, different payload shape, different
on/off switch.

Config (`:foreman_server, :signoz_logs`) is parsed once, in
`packages/foreman_server/config/config.exs`, from four env vars:
`FOREMAN_SIGNOZ_LOGS_ENABLED`, `FOREMAN_SIGNOZ_OTLP_ENDPOINT`,
`FOREMAN_SIGNOZ_OTLP_HEADERS` (comma-separated `key=value` pairs), and
`FOREMAN_SIGNOZ_LOG_LEVEL`. `prod.exs` adds no override — one boundary for
every `MIX_ENV`. Malformed input (unrecognized level, malformed header
pair, or credential headers paired with a non-`https://` endpoint) raises
at config load instead of silently coercing to a default. `config/test.exs`
forces `enabled: false` regardless of the operator's shell env, so `mix
test` never installs the real exporter; tests that need the bridge call
`OtelLogBridge.install/1` directly with a `{:capture, pid}` exporter.

Two security properties are enforced at the export boundary
(`OtelLogBridge.export_to_otel/2`, not just at config-parse time, since
`install/1` is a public function callable with an arbitrary config map):
configured headers are refused for any non-`https://` endpoint (CWE-319),
and the underlying `:httpc.request/4` call sets `autoredirect: false` so a
3xx response can never replay those headers against a different or
less-secure origin.

The blocking `:httpc` POST runs off the logging client process via
`Task.Supervisor.start_child/2` against `ForemanServer.Observability.OtelLogExportSupervisor`
(started under `ForemanServer.Application`, `max_children: 50`); config/payload
validation stays synchronous so `export/2` still reports precondition errors
(missing endpoint, insecure headers, unavailable OTLP protobuf module) to its
caller immediately. A rejected `{:error, :max_children}` emits
`Telemetry.signoz_log_export_overload/1` and drops the record instead of
accumulating unbounded work.

`ForemanServer.Observability.Redactor` and `LogMetadata` are the redaction
boundary: metadata is whitelist-filtered (unknown keys dropped, not
passed through), and log bodies — including structured Erlang `:report`
terms (crash/progress reports) — are walked recursively for sensitive keys
before they are ever inspected into text, then regex-scrubbed again as a
second pass over value-shaped secrets (DB URLs, auth headers, `NAME=value`
secrets, home-directory paths).

## 20.1 Threads (Claude-Projects parity, E6)

`ForemanServer.Threads` is a pure read model over existing projections (task, run, worktree, PR association, review, jobsite); no event backs a thread except the disposition flag. Rules:

- Operator disposition is the `thread.resolve` / `thread.reopen` commands (events `ThreadResolved` / `ThreadReopened` on `thread:<id>`), allowlisted in `CommandGateway`. Config `config :foreman_server, :threads` keys are `idle_resolver`, `idle_resolve_after_days`, `sweep_interval_ms`; `IdleResolver` only sets the flag, never stops a run.
- Live mid-phase steering (docs/plans/live-steering.md): `Workflow.LiveSteer`. Phases of `:claude`/`:pi` launch with harness `provider_options: %{live_input: true}` (config `:live_steering, enabled:`); the dispatcher first calls `LiveSteer.deliver/2` (`Jido.Harness.Run.send_input/3` into the running session; the provider takes it after its in-flight tool call) and only on a typed refusal falls back to pause/resume. System-only commands `run.steer.deliver` / `run.steer.undeliver` append `RunSteerDelivered` / `RunSteerUndelivered`; `run.steer.consume` takes `delivery: live|prompt`. A steer still pending when the run goes terminal (`RunCompleted|Failed|Cancelled|Deleted`) is recorded `RunSteerUndelivered` (projection `undelivered_steering`), never silent. `run.steer.deliver|undeliver` MUST stay out of `@allowed_operator_types`. jido_harness is a GIT dep (`Sunstone-Partners/jido_harness`, ref in `foreman_server/mix.exs`); `packages/jido_harness` is a vendored mirror, change both.
- `jido_harness` is compiled from the vendored `packages/jido_harness` (path dep in `foreman_server/mix.exs`, `override: true`), NOT from the Sunstone-Partners fork; the tree was synced to fork `e41fc165` and Foreman-specific harness changes (live input, `Run.send_input/3`) are ordinary commits there (see `packages/jido_harness/UPSTREAM_PIN.md`). Source-contract tests read `packages/jido_harness/lib/...`, not `deps/jido_harness`.
- Steering fallback is `"pause_resume"` (constant `steering` on the Thread DTO; `Threads.Steerer`). `run.steer` (operator-allowlisted) appends `RunSteerQueued`; the dispatcher pauses the run (the executor commits partial work) and resumes it; `RunExecutor` injects the message into the next phase prompt and then dispatches the system-only `run.steer.consume` (`RunSteerConsumed`) so it is injected once. The durable queue is `RunSteerQueued` minus `RunSteerConsumed`; `RunControl`'s ETS mailbox is only a cache. `run.steer.consume` MUST stay out of `@allowed_operator_types`. Jobsite door: `Jobsite.steer/3` = pause then resume with the jobsite `resume` `prompt` (`POST /api/jobsites/:id/resume`).
- Routes (router.ex): `GET /api/projects/:project_id/threads`, `GET /api/projects/:project_id/threads/find`, `GET /api/threads/:id`, `.../transcript`, `.../stream`, `POST /api/threads/:id/stop`, `POST /api/threads/:id/steer`, `POST /api/threads/:id/rereview` (`Threads.Actions.rereview/1` -> `Review.Analyzer.rerun/2`; 202 / 404 `thread_not_found` / 409 `not_reviewed`, `not_rerunnable`, `already_running` / 422 `archive_unusable` / 503 `analysis_disabled`; no MCP tool). MCP: `foreman_thread_list|get|stop|steer|transcript|find` (`stop` and `steer` are write-gated; `find` and `transcript` are read tools). CLI: `foreman thread list|get|stop|steer|resolve|reopen|rereview`.
- `Threads.Finder` is deterministic (no LLM): exact external_id/branch/PR matches outrank text matches (Jaccard >= 0.5), resolved/deleted threads never text-match. `Threads.Actions.follow_up/2` never starts a run or jobsite: a live thread is steered; a terminal thread with a branch returns `{:error, {:needs_new_run, %{branch:, session_id:}}}`; a resolved thread returns `{:error, :thread_resolved}` (reopen is never implicit).
- Transcripts are bounded and honest about omissions: `run_logs` keep a bounded tail (`omitted_entries` / `truncated`); jobsite turns have no timestamps and no operator turns because jobsite resume prompts are not events.

## 20.2 Overview (Claude-Projects parity, E7)

`ForemanServer.Overview` is the operator's glance at a project: a pure read model over `Threads`, the PR / merge-gate state folded into `ProjectionStore`, review verdicts and approval / question counts (`Overview.Signals`). Rules:

- `Overview.Group.classify/1` is pure and total: `{group, reason}` with groups `ready_for_review`, `waiting_on_you`, `working`, `landing`, `idle`, `resolved` (first match wins; the rules table is in the moduledoc). Unknown status is `{:idle, :unknown_status}`; a closed-without-merge PR classifies `resolved` but is never auto-resolved. An open PR whose watched `checks_state` is `failing` classifies `waiting_on_you` / `ci_failing` (`Input.checks_state`, read from `ProjectionStore.pr_watch/1`). The same watch's `review_decision == "changes_requested"` / non-empty `thread_ids` classify `waiting_on_you` / `changes_requested` / `review_threads` (`Input.review_state`; conversation `comment_ids` are excluded: no resolved state), ranked after `ci_failing`. `ThreadCard.pr_actions` (`Overview.PrActions`) carries the workspace's Fix CI / Address comments / Resolve conflicts / Create PR buttons with disabled reasons; they dispatch the existing `run.pr.*` commands via `Workspace.Actions.pr_action/5`, and there is no merge button.
- PR state is folded by `Overview.PrFold` from `PrAssociated`, `PrReady`, `MergeGatePending/Approved`, `PrUpdated`, `PrMerged`, `PrRetargeted`, `PrReset` into `state.pr_states` (read via `ProjectionStore.pr_state/1`, `pr_states_for_project/1`; also carries the run's `failure_reason`). Folds log and skip malformed payloads; a merged PR is not reopened by a stale `PrUpdated`. `PrReady` itself sets `merge_gate :pending` because the Run aggregate treats it as the gate hold; a separate `MergeGatePending` event is emitted only when a push voids an approval (`run.pr.rehold`, see "Merge gate per PR"), and `PrFold` folds it to `:pending` the same way.
- Surfaces: `GET /api/projects/:project_id/overview` (`include_resolved`, `resolved_limit` 0..200, default 20; 404 `project_not_found`), MCP read tool `foreman_overview` (with `project_id`: full overview; without: one attention line per active project), `attention` / `attention_count` on `GET /api/projects`, `GET /api/projects/:id`, `foreman_project_list` and `foreman_project_get`. Config `config :foreman_server, :overview`: `attention_groups` (default `[:waiting_on_you, :ready_for_review]`; an entry `Overview.Group` does not define raises `ArgumentError`), `tab_providers`, `merge_resolver`, `catch_up_limit`.
- Bound: only the newest `Threads.max_limit/0` (500) threads of a project are classified; `Overview.t()` / the overview DTO / each MCP attention line carry `truncated` (`true` when older threads were left out of `counts`, `attention` and `groups`). Project lists read the threads of all projects once (`Overview.project_fields_many/1`, `Overview.summaries/2` over `Threads.by_project/0`), never once per project.
- Tabs: `pull_requests`, `library` and `scheduled` are built in (`Overview.Tabs.Scheduled`: `{available: true, rows: [Schedule.DTO maps]}`, the same read model as `GET /api/projects/:id/schedules`; a read-model failure is reported as `provider_failed`, not an empty list). A custom `Overview.TabProvider` in `tab_providers` may not name any of the three (it raises like any duplicate). A raising provider only disables its own tab (a `tab/0` that raises is logged and skipped); two providers naming one tab (a configured one shadowing a built-in included) make `Tabs.build/1` raise `ArgumentError`.
- `Overview.Signals` reads pending approvals, open questions and (for a paused thread) expired requests, undelivered approvals and undelivered answers (`undelivered_reason` on an `answered` question; reason `answer_undelivered`, ranked after `question_expired`) from `ProjectionStore`; `Overview.Group.classify/1` turns them into `waiting_on_you` reasons. The marker never clears, so the reason is shown only while the thread is `paused` and goes away once the operator steers the run.
- **Approvals and questions (E8)**: operator commands `tool.approve|deny` and `question.answer`; system commands `tool.request|finish|expire`, `question.open|expire|answer.undeliver` (`Approvals.Dispatch` is the closed list). `question.answer` text is bounded by what the steer cap leaves after the delivery prefix: `Run.steer_text_max_chars/0` (8000) minus `OperatorQuestion.steer_text/2`'s `Answer to your question <id>: ` (`OperatorQuestion.max_answer_chars/1`, per question id); over it is `{:error, {:answer_too_long, length, max}}` (HTTP 422) and nothing is recorded; `question.open` refuses a `question_id` over `OperatorQuestion.max_question_id_chars/0` (200) with `{:question_id_too_long, length, 200}` so that cap never reaches 0. `Questions.Deliverer` sends exactly `steer_text/2`, so there is no second constant: never hard-code 8000 for an answer. An answer recorded before that limit existed and over it can never be delivered: `Questions.Deliverer.recover/1` logs it once at :error and appends the system command `question.answer.undeliver` -> `QuestionAnswerUndelivered` (the question stays `answered`, gains `undelivered_reason`, notifies `Answer could not be delivered`, and is skipped by later recoveries); the operator remedy is `foreman thread steer --message <text> <thread-id>`. Read surfaces: `GET /api/projects/:id/approvals|questions`, `GET /api/runs/:run_id/approvals`, `foreman approvals|questions`, and the read-only MCP tools `foreman_approvals_list` / `foreman_questions_list`, which return the typed `Approvals.Listing` / `Questions.Listing` the HTTP endpoints serialize (one build, shared). `run.steer` accepts the optional `approval_mode_override` (`default|prompt|auto_edit|auto_approve`; `Aggregates.Run` refuses any other name with `{:invalid_approval_mode_override, name}`; stored on `RunSteerQueued`; applied by the next launch, command phases included, and consumed with the message); `Approvals.Deliverer` is its only producer. An approval decides ONE request, but on the post-hoc path (`resume_with_override`) the override is a mode for the whole next phase (no per-tool grant: Claude `bypassPermissions` cannot be narrowed by `allowed_tools`, pinned in `approvals/capability_test.exs`); only `inflight` is per call. Both deliverers recover at start (`recover/1`: approved-unsettled and denied-paused calls, answers of runs that have not ended; deterministic command ids; a run is resumed only while it holds the decision's steer message; a bus reply is never replayed). `Overview.Signals.for_threads/1` reads `ProjectionStore.needs_you_counts/1` once per classification, and a `project.adopt` move re-homes a subject's tool calls and questions with it.
- `Overview.MergeResolver` (a `ProjectionStore` subscriber with a bounded catch-up sweep) dispatches `thread.resolve` (reason `pr_merged`, `command_id` `thread-merged:<thread>:<sha>`) when a PR merges; the live path and the sweep both respect `ThreadReopened` (a merge counts only if its `pr_updated_at` is newer than `reopened_at`), find the thread by run id with no recency window (`Threads.by_run_ids/1`), and it never merges or approves.
- **The merge gate stays operator-only** (`merge_approve` -> `run.pr.merge`). No overview/MCP surface may merge or approve; `test/foreman_server/mcp/no_merge_tool_test.exs` pins this for every advertised MCP tool and cards carry only a text hint.
- **Merge gate per PR (E12-S6)**: `Aggregates.Run.State.merge_gates :: %{repo_key => :pending | :approved}` (`repo_key` `nil` = the run's primary; legacy events without `repo_id` fold into `nil`; read it with `Run.merge_gate/2`). `merge_approve` and `run.pr.merge` take an optional `repo_id` (absent = primary; present only for a non-primary repository on `PrReady`/`MergeGatePending`/`MergeGateApproved`/`PrMerged`). There is NO approve-all; each PR is approved and merged on its own head pin (`RunPrMerge.execute(run_id, repo_id)` reads that repository's approval pin via `Run.merge_pin/2`, falling back to its `PrReady` head only when no pin is recorded). ETS `MergeGate` requester keys are `run:<id>` / `run:<id>:<repo_id>` (`PrGate.gate_key/2`); `approve_by_key` approves only the newest PENDING entry of the key. `merge_approve`, `run.pr.merge` and `run.pr.retry` stay operator-only: never MCP tools, never on the coordinator/approvals/PR-watch dispatch lists (`operator_only_pr_commands_test.exs`).
- **Head-pinned approval and re-hold (foreman-ehxy6)**: `merge_approve` REQUIRES `head_sha` (absent or blank is `{:missing_or_invalid, :head_sha}`; `Run.validate_approval/1` is the one validator, shared by the aggregate and the gateway). `CommandGateway` reads the live PR head (`gh pr view` through `GitHub.PrStatus.fetch`; stub it with `RunPrMerge.set_command_runner/1`) before dispatch and refuses a different head with `{:head_sha_mismatch, supplied, live}`. The recorded `pr_watch` head is NOT the authority: it lags a push and polling is opt-in. `MergeGateApproved.head_sha` is the pin, held in `State.merge_pins :: %{repo_key => %MergePin{pr_url, head_sha, approved_at}}` (a legacy approval event with no `head_sha` pins the `pr_watch` head recorded at that point in the stream). A push after approval returns the gate to `:pending` with the pin cleared: the system-only `run.pr.rehold` (state-based and idempotent: `PrGate.rehold_command/4` asks `Run.stale_approval/4`, the handler emits `MergeGatePending` with `reason: "head_moved_since_approval"`, `approved_head_sha`, `head_sha`) is dispatched by `CommandGateway` after every `run.pr.update|checks|review` observation (`@pr_head_observations`; also when the router deduplicated the observation, because a head returning to an earlier recorded one appends no `PrUpdated`) and by the `run.pr.merge` side effect when `RunPrMerge` answers `head_moved_since_approval` (an unobserved push is caught there). The moved head is never adopted as the pin: only a fresh operator `merge_approve` naming it reopens the gate, and the old approval is never honoured again. The rehold `command_id` carries the approval's `approved_at`, so each approval cycle can be voided once. `run.pr.rehold` is on no operator allowlist and in no MCP/coordinator/approvals dispatch list (`operator_only_pr_commands_test.exs`).
- **Partial completion (E12-S6)**: a multi-repo run whose repo PR cannot be created still completes; finalisation appends `RunRepoPrFailed{run_id, repo_id, reason, at}` (system command `run.repo_pr_failed`, `RepoPr.record_failure/4`), keeps that repo's worktree (`cleanup_run_worktree/3` skips it), and `ProjectionStore.run_repositories/1` reads it as `pr_state: :create_failed` (+ `pr_failure`) until the repo has an association. `completed_with_errors` is DERIVED (`OperatorDashboard.RunDTO`), never a run status. The operator retries with `run.pr.retry {run_id, repo_id}` (`RepoPr.retry/2`: idempotent, allowed on terminal runs, reclaims the worktree on success). Single-repo runs emit no `RunRepoPrFailed`.
- **Live multi-repo e2e and rollback caveat (E12-S12)**: `scripts/e2e/multi_repo.sh` (POSIX sh; run it as `devbox run -- sh scripts/e2e/multi_repo.sh`; assets in `scripts/e2e/multi_repo/`) drives ONE real task over two scratch git repos (local bare origins, recording fake `gh`, private port and database, real `pi` + MiniMax agent) and asserts worktrees, sibling-path edit, commits, pushed branches, two PRs, archive `diffs/b.patch` + manifest `repositories[]`, the per-repo merge gate, a read-only-origin failure with `run retry-pr` recovery, and an unchanged single-repo run. The recorded transcript is `docs/lessons/multi-repo-e2e-2026-10-21.md`. **Rollback caveat (release note)**: single-repo runs write no new event keys, so rolling back after this release but before any multi-repo run is safe; an older binary raises when it replays an event that carries `repo_id`/`repo_ids`, and those exist only after the first multi-repo run. After that first run rolling back to a build without E12 is NOT safe; `runs: false` stops new multi-repo runs but cannot remove events already written.
- **Live Claude Projects acceptance (E16-S8)**: `scripts/e2e/claude_projects_flow.sh` and `scripts/e2e/failure_injection.sh [scenario ...]` (bash; `devbox run -- bash scripts/e2e/<script>`; shared harness and assets in `scripts/e2e/claude_projects/`: `lib.sh`, `boot.exs`, `webhook_listener.py`, scratch `workflows/` pinned to pi/minimax, not the bundled defaults). Each starts its own throwaway server (private Postgres database `foreman_e2e_claude_projects_<cp|fail>`, port, scratch git repo with a local bare origin and its own `br` database, redirected `HOME`, `FOREMAN_VFS_ALLOWED_ROOT`, local webhook sink, real `pi` agent) and prints `PASS`/`FAIL`/`UNVERIFIED` per assertion; exit 3 on any FAIL; only its own PIDs/database/work dir are cleaned up (`E2E_KEEP=1` keeps them). The flow covers project settings, memory, library, a bead imported by `BeadsWatcher` into a thread that sees instructions/memory/library, steer/stop/resolve/reopen, Overview groups, coordinator chat, notifications and the review archive with its bead comment. Failure scenarios: `provider-down`, `agent-crash`, `coordinator-crash`, `server-crash` (exec-port + server `kill -9` -> `OrphanReaper` #607), `port-closed` (exec-port only `kill -9`, server alive -> the failed run's cleanup reaps the orphaned agent, foreman-zmhzw), `cancel-strays` (`run cancel` and `thread stop` of a run blocked in a `sleep 300` tool -> the agent AND the tool process, which runs in a session of its own, are gone: nothing is left running in the run's worktree, foreman-zmhzw), `shutdown-strays` (SIGTERM of the server with such a run in flight -> the same, foreman-zmhzw), `project-paused`, `br-down`. Approve/deny and question/answer are reported UNVERIFIED by the scripts (pi has no permission mechanism); real GitHub is exercised only when `FOREMAN_E2E_GITHUB_REPO` is set (stage 8, `docs/acceptance/github-live-run.md`), and the Claude provider paths have their own live write-ups (`docs/acceptance/README.md`). Evidence: `docs/acceptance/claude-projects-acceptance-2026-10-22.md`; per-capability verdicts: `docs/acceptance/parity-audit.md`; runbook: `docs/acceptance/README.md` and `docs/user-guide.md` "Running the live acceptance".
- **Failure evidence of the live harnesses (foreman-azc2o)**: the harness removes its work dir and drops its database at exit, so `scripts/e2e/claude_projects/lib.sh` `cleanup` (installed by `install_traps`, i.e. every harness that sources it) calls `evidence_keep` WHILE THE SERVER IS STILL UP whenever the harness exits non-zero or an assertion failed (`E2E_EVIDENCE=always` also on a pass, `E2E_EVIDENCE=0` off). It writes `summary.txt` (exit status, failed assertions, every run that did not complete with its `failure_reason`, failure events, server-log errors), `server.log`, `notifications.jsonl`, `api/` (project, threads, Overview, runs and each thread's projection/transcript/task), `events.jsonl` (`claude_projects/event_store_dump.exs`: every event of the throwaway event store, decoded), `agent-sessions/` (pi's own session files), `run-artifacts/`, `worktrees/` + `worktrees.txt`, `repo-beads/`, `repo.bundle` (every ref of the scratch repository, bounded by `E2E_EVIDENCE_REPO_MAX_KB` = 204800: a completed thread's committed branch lives there once its worktree is gone), `environment.txt` (load, disk, memory, the other harness stacks alive, the database's connections and what `pi --list-models <model>`, the kickoff preflight's own question, answers then), `processes.txt` and `database.dump` (`pg_dump -Fc`) to `$E2E_EVIDENCE_DIR/<name>-<UTC start time>-<pid>/` (default `<checkout>/tmp/e2e-evidence`, git-ignored; `github_live_extras.sh` keeps its `tmp/gx-evidence`). Every part is best effort and says what it could not keep, and the capture runs in a subshell so it can never skip the teardown. `claude_projects_flow.sh`'s `wait_thread` stops waiting for a thread that has sat in `failed`/`cancelled` for `E2E_FAILED_GRACE` seconds (default 20) instead of `E2E_RUN_TIMEOUT`; `E2E_FIRST_THREAD_ONLY=1` runs setup and steps 1-3 only (about 30 s), the loop for an intermittent first-thread failure.
- **Live Claude + in-flight approvals harness**: `scripts/e2e/live_claude/` (`stack.sh up|restart|crash|stop|start|down`, `approvals_ui.mjs` Playwright driver, `events.exs`/`rpc.sh`, `fake-old-claude.sh` SIMULATED old CLI, claude workflows `claudeedit`/`claudeprompt`): a long-lived private stack with REAL claude (redirected `HOME` with the claude auth symlinks, `TMPDIR` under the scratch dir), driven step by step; evidence in `docs/acceptance/live-claude-and-approvals.md`. Live finding: Cowboy's 60 s `idle_timeout` (no data RECEIVED) used to kill a blocked in-flight prompt, so `AgentPermissionController` lifts the idle timeout of that stream. Orphaned in-flight requests (a restart, a run that ends with nobody waiting, a killed connection) are expired by `Approvals.Inflight` (reasons `server_restart` / `run_ended` / `client_gone`; a late decision is refused with `{:tool_call_expired, reason}`; the approvals DTO carries `reason` and `outcome`; foreman-u0646), and `Approvals.ClaudeCli` probes the claude CLI (`FOREMAN_CLAUDE_CLI`, else `claude`) for `--permission-prompt-tool` at launch so an old CLI falls back to the pause-and-re-run path instead of failing the phase (foreman-dc618; `claude --help` cannot tell, the flag is hidden from it). Both fixes are unit-tested with fake CLIs and were not re-run live.
## 20.3 Scheduled tasks (E11)

- `Aggregates.Schedule` (`schedule:<project_id>:<schedule_id>`): operator commands `schedule.create|update|pause|resume|delete` (allowlisted in `CommandGateway` and `CommandController`; the controller/gateway derive the composite id, `schedule.create` without an id generates `sch-<hex>`), system commands `schedule.mark_fired` / `schedule.skip_fire` (never operator-allowlisted). Events `ScheduleCreated|Updated|Paused|Resumed|Deleted|Fired|FireSkipped`. The aggregate is pure: `at` is stamped by the gateway (client values overwritten) or the ticker; slot dedupe is `slot <= last_slot` -> `{:slot_already_processed, slot}`.
- `Schedule.Spec` is the typed boundary (hand-written 5-field cron with Vixie dom/dow OR, interval specs, UTC only). `crontab` (transitive via jido) was evaluated and NOT adopted: it ANDs dom/dow and accepts syntax Foreman rejects. `latest_slot_at_or_before/3` returns ONE slot: that is the no-catch-up-storm primitive.
- `Schedule.Planner` (pure) decides fire/skip/wait; `Schedule.Ticker` (supervised, `:schedule, ticker_enabled`) runs the idempotent fire sequence over `SchedulerIntent` (the crash marker) and redoes interrupted intents via `Recovery.interrupted_intents/2`. `Aggregates.Scheduler` (tick/claim/skip, never routed) was removed; `Recovery.detect_unconfirmed_intents/1` was replaced. A slot whose task exists is recorded as fired, never skipped; recovery judges each interrupted intent with `Planner.misfired?/3` (late: recorded as a `missed` skip) and `Planner.accounted_for?/2` (already consumed or before the baseline: no task, intent closed) instead of redoing it blindly; every error the ticker does not classify keeps the intent recorded for a retry.
- Reads: `ProjectionStore.schedules/2`, `schedule/2`, `all_active_schedules/0`; wire shape `Schedule.DTO` (`GET /api/projects/:id/schedules`, MCP `foreman_schedule_list`). Write MCP tools (`foreman_schedule_create|update|pause|resume|delete`) are in `MCP.Policy.write_tools/0` (single source of truth for the write gate AND the `McpAllowlist` seed in `Application`); `test/foreman_server/mcp/tool_inventory_test.exs` pins the full tool list, the write set, that no tool merges/approves, and that each tool is documented in the user guide or CLI reference — adding a tool means updating it.
- Surfaces over `schedule.*`: CLI `foreman project schedule list|create|update|pause|resume|delete` (`update` sends only the flags passed; a spec is replaced wholesale), MCP `foreman_schedule_update` (no `request_id`: each call is a new command), and the workspace Scheduled tab (Pause/Resume and Delete -> Confirm delete / Cancel, events `schedule_confirm_delete|schedule_cancel_delete|schedule_delete`, over `schedule.delete`). `Overview.Tabs.Scheduled` serves `tabs.scheduled` from the same read model.

## 20.4 Project coordinator (Claude-Projects parity, E15)

- One event-sourced conversation per project, stream `coordinator:<project_id>` (`Aggregates.Coordinator`). Operator-allowed commands: `coordinator.message`, `coordinator.restart` (the one allowlist in `CommandGateway`, which `CommandController` reads; add the type to the controller's `aggregate_prefix/1`/`id_field_for/1` too); `coordinator.append`, `.turn.start`, `.action.record`, `.turn.complete`, `.turn.fail`, `.usage.record` are system-only and MUST stay off every operator allowlist. `Aggregates.Coordinator.apply_event/2` ends in a catch-all (an unknown event type must not crash replay). The read model is `Coordinator.Conversation`, folded in `ProjectionStore` (`coordinator_state/1`, `coordinator_conversation/2`, `coordinator_status/1`, `coordinator_pending_projects/0`); `seq` is assigned in the fold so a rebuild yields identical cursors. The page the CLI/HTTP/MCP read carries `status` AND `pending_messages` (trigger messages no completed turn consumed): `status` is `idle` between two turns while a message is still pending, so a waiting client (`foreman project chat`) must wait for `idle` and `pending_messages: 0`.
- `Coordinator.Runner` (subscribe FIRST, then scan `coordinator_pending_projects/0`, because `replay_existing: false` loses messages appended while down) wakes one `Coordinator.ProjectWorker` per project; `Coordinator.TurnRunner` runs context -> agent -> reply -> actions -> `turn.complete`. The turn id is `<first trigger message id>:a<attempt>`; the reply message id is `reply:<trigger message id>`; action ids are `sha256(project, trigger, action)` (`Coordinator.Action`), command ids derive from them: re-running an interrupted turn must be a no-op for effects already done. Never put a timestamp or random value in a coordinator command id. A turn task is LINKED to its `ProjectWorker` (which traps exits), so a worker crash ends its turn, and every turn registers `{:turn, project_id}` in the runtime registry, so a replacement worker answers `{:failed, :turn_in_flight}` and retries instead of running a second concurrent turn (E16 acceptance defect foreman-42t7a).
- The agent is behind `Coordinator.Agent` (`Agent.Harness` in production: provider agent via `DetachedRun`, `sandbox_mode: :read_only`, scratch cwd, pi with extensions/skills/MCP/session off; `Agent.Stub` in tests, driven by a per-test script process, never global env). Output contract = one fenced JSON block parsed by `Coordinator.ActionSource`; a bad block is `:malformed_output` and executes nothing (one repair retry in `Harness`). Unit/integration tests MUST NOT call a live provider.
- `Coordinator.Executor` is the single choke point for effects; every command goes through `Coordinator.Dispatch.system/2` whose `@command_types` is closed (no `merge_approve`, `run.pr.merge`, `project.archive`, `task.retry`, ...). Authority (`Coordinator.Authority`): an operator-authored message from a source not in `untrusted_sources` gives `:operator`; reports, agent and MCP messages give `:machine`, which `Coordinator.Policy` limits to answer/ask/propose_threads/route_followup/remember. Tuning (`Coordinator.Tuning`, settings `coordinator_propose_before_start|max_active_threads|reuse_threads`) is enforced in the Executor, not the prompt. Third-party text in prompts goes through `Coordinator.Untrusted.wrap/2`; stored text through `Coordinator.Redact`. `Coordinator.MemoryGuard` refuses merge/approve-automation notes. Do not add an action kind without a Policy decision, a recorded outcome and an adversarial test.
- `add_repo` and `schedule` are operator-grade actions. They need an operator turn AND the operator's own words (`quote`, verified by `Coordinator.Policy.quote_verified?/2` like loosening `set_tuning`); `Coordinator.Dispatch` then sends `project.repo.add` / `schedule.create` through `CommandGateway.dispatch_operator/1` (never `dispatch_system`), so the repository checks (realpath, git work tree, not a member, remote identity) and the schedule limits (interval floor, per-project cap, installed workflow, `at` stamped by the gateway) are exactly those of `foreman project repo add` / `foreman project schedule create`. Command ids are `coord:repo.add:<action id>` and `coord:schedule.create:<action id>` (the schedule id is the MCP `foreman_schedule_create` derivation with the action id as request id); a re-run of an `add_repo` already done answers `executed` with `already_registered`, and a schedule is created with `auto_approve: false` when the project's `propose_before_start` is on. The `schedule` action carries `spec` (interval or 5-field UTC cron), `prompt`, `workflow` or `task_type` (chosen by `WorkflowSelector`, like a thread) and an optional `name`.
- A thread the coordinator starts or proposes (and a `schedule`) must say how its workflow is chosen: `WorkflowSelector` takes an explicit installed `workflow`, else a `task_type` that `Catalog.type_to_workflow/1` maps, else `:no_workflow` (rejected, recorded and shown to the operator, nothing starts). The action schema marks both keys optional, so the contract lives in the prompt (`priv/coordinator/system_prompt.md`: `start_thread`/`propose_threads` say "workflow or task_type (at least one)", rule 6) and in the `# WORKFLOWS` section, where `Sources.Live.workflows/0` lists per workflow the task types that resolve to it (`[task_type: bug, chore]`, read from `Catalog.type_to_workflow_map/0`, the selector's own map). Without that the real coordinator left both keys out in about 8% of three-item pastes and all three threads were rejected (foreman-ig27o); `thread_workflow_contract_test.exs` pins the prompt and the source.
- Coordinator usage: the `TurnRunner` records the provider usage of every turn that ran a provider (also a turn that then fails) with `coordinator.usage.record` -> `CoordinatorUsageRecorded` (command id `coordinator:usage:<project>:<turn id>`, so a replay appends nothing twice). It is NOT `UsageRecorded`: that event is run-keyed and its fold creates a run projection. The fold feeds the shared usage ledger under role `coordinator` with `thread_id: nil`, so the usage rollup counts it in the total and the day/model/provider/role breakdowns but not in `by_thread`. Counts and cost stay nil-preserving (`Usage.from_run_result/1`, repair-retry attempts summed in `Agent.Harness`); an all-nil usage is not recorded. Each turn logs one `info` line when it starts (trigger ids with role/kind/source) and one when it completes (authority, reply bytes, action kinds with their status and reason), plus a `warning` when it fails or `turn.complete` is refused: that is what to read when a turn produced no threads.
- `Threads.Actions.follow_up/3` takes steer options (`message_id:` makes a repeated follow-up a no-op); the coordinator passes `coord-<action id>`.

## 21. Outbound messaging delivery

`ForemanServer.Notifier` (supervised, started by default; `config :foreman_server, :start_notifier?, false` stops it) is the production producer of `Messaging.notify/2`. It subscribes to projection events (no replay) and maps them through the table in `ForemanServer.Notifier.Mapping`: run/jobsite failure and CI failing -> `failure`; run stall (`RunStallReported`, `RunFlaggedStuck`) -> `stall`; a blocked run (`RunBlocked`), a not-met review verdict, an agent question, an approval request/expiry, PR changes requested and exhausted PR fix attempts -> `action_needed`; run or jobsite completed, PR ready for review and any other review verdict -> `run_update`. Rows match by event name only (`RunFailed`, `JobsiteFailed`, `RunStallReported`, `RunFlaggedStuck`, `RunBlocked`, `RunCompleted`, `JobsiteCompleted`, `ReviewRecorded`, `QuestionOpened`, `QuestionExpired`, `ToolCallRequested`, `ToolCallExpired`, `PrReady`, `PrChecksChanged`, `PrReviewChanged`, `PrFixExhausted`); an event Foreman does not produce simply never matches. The PR row is `PrReady`, which every PR a run opens records (AutoPR, a stacked phase PR, another repository's PR, the Create PR button); `PrCreated` is only the button's audit fact and is deliberately unmapped, so one PR is announced once (foreman-ehz7l). `RunCancelled` and `JobsiteCancelled` are unmapped on purpose (an explicit stop), and the Notifier skips `JobsiteCompleted` for the jobsite of a PR fix thread (the PR's own events report that fix). Extend or override rows with `config :foreman_server, :notifier, rules: [%{event_type:, class:, severity:, level: :blocked | :progress, subject:, key_fields: [...], body_fields: [...], match: %{field => [values]}, url_field:}]` (configured rules win; a malformed rule raises at startup). Per project, the `notification_preference` setting (`every_turn`, `blocked_only` (default) or `off`) filters by level: `blocked_only` delivers only failures, stalls, blocked runs, needs-input, approvals, CI failing and review not met; `every_turn` also delivers progress rows and enables the `run_update` class for that notification; `off` delivers nothing. `run_update_rate_limit_ms` is enforced by the Notifier: at most one `run_update` per run per window (a run's PR ready and its completion share one). Replays collapse through the `dedupe_window_ms` check because the correlation id is a digest of the event type and the rule's `key_fields`. Notification events never carry a secret: the recipient is the label `default` and Slack/webhook destinations are resolved from config by the dispatcher (a Slack or webhook recipient is never used as the URL). A Slack webhook URL (env or any config) must be https, no userinfo, public host, no opt-out: `{:unsafe_url, :slack_destination, reason}` / `{:invalid_field, :slack_destination, :webhook_url}` at config resolve and again before each send (`Providers.Slack`). A third provider, `webhook: [url:, secret:, allow_insecure_http:, allow_private_hosts:]` (`url` literal or `{:system, "ENV"}`; https, no userinfo and no private host (loopback, link-local, RFC 1918, carrier-grade NAT, `localhost`) unless the matching `allow_*` opt-out is `true`; optional `secret` signs the body with HMAC-SHA256 in `x-foreman-signature`; every request carries `x-foreman-delivery: <notification id>`), POSTs a `foreman.notification.v1` JSON document. `ForemanServer.Messaging.WebhookUrl` judges the URL when the config resolves (`check/2`, no network; refusal `{:unsafe_url, :webhook_destination, :insecure_http | :userinfo | :private_host}`) and again before each send (`check_resolved/3`: a `{:system, "ENV"}` URL and every address a host name resolves to; an unsafe URL fails the delivery terminally, an unresolvable host retryably; no reason carries the URL). Env wiring: `FOREMAN_NOTIFY_WEBHOOK_URL`, plus `FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP=true` and `FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS=true` for an http or private-network receiver (a local http sink needs both). `Notifier.status/0` and `Notifier.stats/1` back the `notifier` row of `GET /api/doctor` (`foreman doctor`): off is `ok`; enabled with an invalid config, a stopped notifier or dispatcher, or refused events is `warn`. There is no desktop-push provider.

Keep outbound chat delivery behind `ForemanServer.Messaging`. Runtime/run/recovery/inbox code may enqueue provider-neutral notifications only; provider HTTP belongs in `ForemanServer.Messaging.Providers.*`. `ForemanServer.Messaging.Dispatcher` is supervised after `CommandRouter`. On boot it replays the event log and redelivers any enqueued notification that has no durable terminal outcome — a bare delivery-attempt event (crashed mid-send) or a retryable failure is redelivered, not treated as done; only a recorded success or a non-retryable failure is terminal. Within one dispatcher process lifetime, the first delivery attempt (from catch-up or a live projection event) claims the notification id for the rest of that process's life, so a notification enqueued during dispatcher startup cannot be delivered twice by both paths racing. A catch-up read failure or a projection-subscribe failure crashes the dispatcher under supervision rather than silently continuing without live/replay delivery. Redact provider URLs/tokens/errors before persistence/logging. Provider delivery failure is notification lifecycle state, not a recursive run failure trigger.


## 22. Project memory

A project keeps agent- and operator-written memory under `<project path>/.foreman/memory/` (`MEMORY.md` index plus one `<topic>.md` per topic). Content lives on disk, never in events: `ProjectMemoryWritten` / `ProjectMemoryForgotten` (stream `project_memory:<project_id>`, `Aggregates.ProjectMemory`) carry metadata only (name, description, sha256, bytes, redaction count, author). Always go through `ForemanServer.ProjectMemory` (`write/3`, `forget/3`, `list/1`, `read/2`, `index/1`, `verify/1`, `sync/2`); it takes a per-project lock, redacts (log-policy patterns plus `ProjectEnvironment.secrets/1`: every secret-store value and the values of secret-named env vars) before the disk write, enforces caps (`config :foreman_server, :project_memory`: 64 KiB topic, 200 topics, index 200 lines / 25 KiB), rejects log/env dumps (`:content_not_durable`, thresholds in the same config) and rolls the file back if the audit command is rejected. `ForemanServer.ProjectMemory.Store` is the filesystem layer and has no CQRS knowledge; `project.memory.write|forget` are system-dispatched only and must NEVER be added to `@allowed_operator_types` / the operator allowlist. `ForemanServer.ForemanDir.ensure_ignored/2` appends `memory/` to `.foreman/.gitignore`; only content paths are ever ignored (`.foreman/Dockerfile`, `bead.exs`, `pi-models.json` stay tracked). MCP: `foreman_project_memory_list|read` (read-only) and `foreman_project_memory_write|forget` (in `MCP.Policy.@write_tools`); their descriptions come from `ProjectMemory.Guidance`, whose `text/0` is the block E3 injects. Operator surfaces: `/api/projects/:id/memory[/:name|/sync]` (`ProjectMemoryController`) and `foreman project memory list|read|write|forget|sync`. The audit command ids carry a unique suffix on purpose: event ids derive from `command_id`, so a content-only id would silently drop a later A -> B -> A rewrite.

## 23. Standing context injection

`ForemanServer.ProjectContext.build/2` is the ONLY producer of standing project context (instructions, repositories, provider sections such as `ProjectContext.Memory`); never assemble it elsewhere. Config `:foreman_server, :project_context` (`max_chars`, `section_caps`, `section_providers`); every cap and the total budget count CHARACTERS (`String.length/1`), the unit of the settings limits, so instructions the validator accepted (16000 characters) are never cut for being multibyte. It returns a `%ProjectContext.Bundle{}` (`system_text` nil when empty, `sections`, `truncated`, `bytes`, `sha256`, `redactions`); truncation is visible inside the text (`[truncated: N lines omitted from ...]`), caps cut at line/character boundaries (`truncated[].omitted_bytes` and `bytes` stay byte counts of what was cut and of the final text), and a section `trailer` always follows a cut body so delimited blocks stay closed. Memory is agent-written, so it renders inside `<project_notes>` labelled informational, never as instructions. `ProjectContext.deliver/3` decides delivery by provider capability: `system_prompt` where the adapter declares it, else prefixed to the prompt. Workflow door: `RunExecutor.build_agent_launch` builds per launch and `append_system_prompt/2` merges with (never overwrites) the command-phase inbox prompt (context first); `prompt_template_assigns/4` exposes `project_context` / `project_instructions` / `project_memory`. Jobsite door: `Executor.build_program` builds once per jobsite into the agent step opts (`project_context`), `Engine` passes `system_prompt` in `runner_opts`, `AgentRunner` puts it into the `RunRequest`. `Review.Capture.put_project_context/2` and `put_run_project_context/2` archive `project-context.md` plus a manifest `project_context` block (first launch only). Read-only inspection: `GET /api/projects/:id/context`, `foreman project context`. `Jobsite.resume` rebuilds the context from the aggregate's `project_id` and re-sends it.

The `Repositories` section carries the project checkout's path as ORIENTATION ONLY (foreman-2onq1): its line says it is the main checkout, that every thread works in its OWN git worktree (its current working directory) and that nothing is to be written under the path or put into a worker's prompt. Handed over bare (`- primary: <path>`), the coordinator copied it into a worker's brief (`Repository: <path>` ... "at the repository root") and the worker obeyed it: it wrote its file into the main checkout, the run's branch came out empty and step 5b of the live flow failed (1 of 20 runs). `priv/coordinator/system_prompt.md` rule 13 tells the coordinator never to put the checkout's absolute path in a thread's `prompt` (paths inside pasted data, such as a stack trace, stay verbatim; `ProjectContextTest` and `ThreadWorkflowContractTest` pin both texts). This is prompt-level only: nothing deterministic stops an agent that writes into the main checkout anyway.

## 24. PR watching and bounded auto-fix (E9)

`ForemanServer.PrWatcher` (config `:pr_watcher`, `enabled: false` or `FOREMAN_PR_WATCHER_ENABLED=false` stops it) folds observed PR state into the run's `pr_watch` projection through typed events `PrChecksChanged`, `PrReviewChanged`, `PrFixRequested`, `PrFixStarted`, `PrFixFinished`, `PrFixExhausted`, `PrCreated`, `PrWatchStarted`, `PrWatchStopped` (commands `run.pr.checks|review|fix_ci|address_comments|resolve_conflicts|fix_started|fix_finished|fix_exhausted|create|watch_stop|watch_start`). Polling is the separate opt-in `ForemanServer.PrMonitor` (`FOREMAN_PR_MONITOR_ENABLED=true`; pending checks 30 s, recent change 60 s, stable `:pr_monitor_interval_ms` 5 min, idle >24 h 15 min, +/-10% jitter); GitHub webhooks only make a PR current early: `check_run`/`check_suite` (`completed`, `rerequested`), `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread`, PR `issue_comment` and `pull_request` `synchronize|ready_for_review|converted_to_draft` ask `PrWatcher` to re-read it, while a `pull_request` `closed|reopened` (or any other action on a conflicted PR) appends `PrUpdated` itself. A fix thread (`ForemanServer.PrFix.plan/4`) is a jobsite with `push: true` on the PR head branch via fast-forward-only `Worktree` `sync_remote` (never force). PR text and CI logs are untrusted and fenced in the prompt. The loop guard lives in the Run aggregate (`Aggregates.Run.PrWatch`): one fix in flight per PR, hard cap 5 attempts per kind, a fix that changed nothing on the same head is `no_progress`, optional cooldown; a fix that cannot start or whose start task crashes is finished as `failed` (`PrFixFinished.error_code`: the typed start error, `start_crashed`, or `lost_on_restart` for a request a restart found without a jobsite), never left in flight; automatic fixes (`pr_auto_fix` project setting, `PrWatcher.AutoFix`) are off until a project opts in. **Merge stays operator-only**: `merge_approve`/`run.pr.merge` are not in `PrWatch.operator_types/0` and no MCP tool, reactor or auto-fix path can merge or approve. The one thing a PR observation does to the gate is make it stricter: a head it records that differs from an approved PR's pin voids the approval (`CommandGateway` sends the system-only `run.pr.rehold`; see "Merge gate per PR" and "Head-pinned approval"). Surfaces: `GET /api/runs/:id/prs`, MCP `foreman_pr_status` (read) and `foreman_pr_fix`/`foreman_pr_watch_stop` (writes), CLI `foreman run prs|fix-ci|address-comments|resolve-conflicts|create-pr|watch-stop|watch-start`. Live webhook delivery, force-push handling, check re-run, conflict resolution and unresolved-thread reads are UNVERIFIED against real GitHub (spike S4). **Multi-repo (E12-S7)**: a PR is addressed as `{run_id, repo_id}`: `ProjectionStore.run_ids_for_pr_url/1` returns `[{run_id, repo_id}]` (primary included), `PrUpdate.command/4` / `PrObservation.commands/5` and the watch lifecycle commands carry `repo_id` only for a non-primary repository (absent == the run's primary), the watch fold never erases a recorded `repo_id`, and `PrFix.plan/4` attaches the PR's own repository path and worktree only. A merged/closed PR of repo b never touches repo a's record or gate.

## 25. Project library

A project's library is a read-only file store every agent of the project can use (Claude "Project knowledge" parity), at `<project primary repo>/.foreman/library/<entry_id>/{entry.json,files/...}`. ONLY `library/` is gitignored (`ForemanDir.ensure_ignored(path, "library/")`); `.foreman/Dockerfile`, `bead.exs` and `pi-models.json` stay tracked, and `Library.StoreTest` pins that with `git check-ignore`. Bytes live on disk, never in events: `ProjectLibraryAdded` / `Replaced` / `Removed` (stream `project_library:<project_id>`, `Aggregates.ProjectLibrary`) carry metadata only (entry id, name, kind, counts, manifest digest, source, skipped summary, author). Always go through `ForemanServer.Library` (`add/4`, `replace/5`, `remove/3`, `list/1`, `get/2`, `read/3`, `index/1`, `env/1`, `delivery/2`, `register_produced/4`); it takes a per-project `:global` lock, plans with `Library.Ingest`, writes to disk with `Library.Store` (staging dir + rename swap, files 0444 / dirs 0555, streamed sha256), then dispatches the system command (not on the operator allowlist, like memory); a rejected command rolls the disk back. Replace/remove need a unique `command_id` (the event id derives from it, so a deterministic one drops an A -> B -> A rewrite). Limits mirror Claude and live in `config :foreman_server, :library`: at most 100 files per add, 480 MB per file, 512 MiB per add in total (`upload_max_bytes`: one request, 413 `upload_too_large` beyond it, reported in the `limits` of the list response; the CLI refuses a larger plan locally); a folder takes the first 100 files within 200 MB (sorted, depth-first), skipping hidden files, `node_modules`, symlinks and files over 30 MB; at most 10 `folder` entries per project (aggregate guard `{:too_many_folders, 10}`); every skipped file is reported back with a reason. Delivery: `FOREMAN_LIBRARY_PATH` is set only when the library is non-empty — the absolute host directory on the workflow door and the host sandbox, a read-only bind mount at `/library` for docker jobsites (`Library.delivery/2`; nothing is copied or linked into the worktree because Foreman commits the whole worktree); the index is the `ProjectContext.Library` section provider. Thread-produced files (`PhaseCompleted` artifacts and the session archive's `analysis.md` / `diff.patch`) are registered by `Library.Collector` into one `produced-<run_id>` entry (kind `produced`, exempt from the folder cap, idempotent per run/path/sha256, bounded by `produced_max_files_per_run` / `produced_max_bytes_per_run`, containment-checked against the run's directories) ONLY when the project setting `library_collect_produced` is true. Surfaces: HTTP `ProjectLibraryController` (multipart upload with a raised, route-scoped body limit via `Plugs.LibraryUploadParser`; `server_path` adds need `allow_server_paths: true`; every API write is audited with author `operator`/`api` because the API has one shared bearer token: the caller-supplied `x-foreman-operator` header is not an identity and is ignored here), read-only MCP tools (`MCP.LibraryTools`: no add/remove tool for agents) and `foreman project library list|add|replace|remove`.

## 26. Claude-Projects invariants (cross-cutting contracts)

Rules that hold across every project-workspace capability (E0-E11, E13-E16). Each names its enforcing code and the test that pins it; a change that weakens one needs the operator's explicit word.

- **Typed boundaries.** Full rules in `AGENTS.md` §5 / `docs/lessons/typed-boundaries-full.md`: no bare result maps at a boundary, total result handling, ONE key convention per boundary, no rescue-all. Project settings are atom-keyed after `Aggregates.Project.Settings.normalize/1`; the whitelist is `Settings.keys/0`: `goal`, `instructions`, `thread_model`, `thread_effort`, `coordinator_provider`, `coordinator_model`, `coordinator_effort`, `max_concurrent_runs`, `daily_thread_cap`, `pr_auto_fix`, `coordinator_propose_before_start`, `coordinator_max_active_threads`, `coordinator_reuse_threads`, `library_collect_produced`, `notification_preference`. An unknown key is rejected (`{:unknown_setting, key}`). A new setting is one entry there plus the CLI flag (`packages/foreman_cli/cmd/foreman/project.go`) and the settings table in `docs/user-guide.md`.
- **The merge gate is operator-only.** `merge_approve` and `run.pr.merge` are reachable only through the operator allowlist. They are absent from `Coordinator.Dispatch.@command_types`, from `Aggregates.Run.PrWatch.operator_types/0` and from every MCP tool, and the PR watcher, auto-fix, `Overview.MergeResolver` and notifications never call them. Pinned by `test/foreman_server/coordinator/executor_test.exs`, `test/foreman_server/mcp/no_merge_tool_test.exs` and `test/foreman_server/mcp/tool_inventory_test.exs`.
- **System-only commands stay off the operator allowlists.** Never allowlist `coordinator.append|turn.start|turn.complete|turn.fail|action.record`, `run.steer.consume|deliver|undeliver`, `schedule.mark_fired|skip_fire`, `review.record`, the project memory/library commands, the PR observation commands (`run.pr.checks|review|fix_started|fix_finished|fix_exhausted`) or the merge-gate re-hold `run.pr.rehold`. Operator commands live in ONE list, `CommandGateway` (`operator_types/0`, `command_endpoint_types/0` for `POST /api/commands`, `schedule_operator_types/0`, `pr_operator_types/0`, `decision_operator_types/0`); `CommandController` reads it and keeps no copy (`test/foreman_server/command_allowlist_parity_test.exs` pins both entry points' behaviour).
- **Every aggregate prefix is registered** in `CommandRouter.aggregate_module_for/1` (`command_router.ex`), and every aggregate's `apply_event/2` ends in a catch-all clause so an unknown event type cannot crash replay.
- **`EventCodec` rejects unknown keys** (`event_codec.ex`; `test/foreman_server/event_codec_test.exs`). A field added to an existing event struct MUST NOT be in `@enforce_keys`, or historical events stop decoding. Event types are discovered by scanning `events/**/*.ex`; there is no registry to edit.
- **No secret or content bytes in events.** `ProjectSecretSet` carries name and version only; memory and library events carry metadata (name, sha256, sizes, counts), never bytes; secret values are redacted from logs, MCP results and archives (`test/foreman_server/project_secrets_test.exs`). Notification recipients are the label `default`, never a URL or token.
- **LiveViews subscribe, they do not poll.** `ForemanServerWeb.Workspace.Refresh` subscribes once to `ProjectionStore` and coalesces bursts (`config :foreman_server, :workspace, coalesce_ms:`, default 250); `test/foreman_server_web/live/project_workspace_live_test.exs`.
- **Paused/archived enforcement points.** A paused or archived project refuses `task.create` (`Aggregates.Task.validate_project_allows_tasks/1`, `{:project_paused, id}` / `{:project_archived, id}`), thread reservation for runs and jobsites (`Aggregates.Project`, `reject_paused/2`), jobsite start (`Jobsite.Executor`, `:spec_project_unavailable`) and `BeadsWatcher` imports (held, not skipped); schedule fires record a `project_paused` skip (`Schedule.Planner`). In-flight work continues. Tests: `aggregates/task_paused_project_test.exs`, `run_admission_project_refusal_test.exs`, `schedule/planner_test.exs`, `task_providers/beads_watcher_pipeline_test.exs`.
- **Standing context (§23).** `ProjectContext.build/2` is the only producer; truncation is visible in the text; memory renders as informational `<project_notes>`, never as instructions; delivery follows the provider's `system_prompt` capability.
- **Library rules (§25).** Bytes on disk, metadata in events; ONLY `library/` is gitignored; delivery is read-only via `FOREMAN_LIBRARY_PATH` (host) or a read-only `/library` mount (docker), never copied into the worktree; agents have read-only MCP tools only; limits mirror Claude and every skipped file is reported with a reason (`Library.StoreTest`).
- **PR watching loop guards (§24).** One fix in flight per PR (any kind), hard cap 5 attempts per kind including operators (`Aggregates.Run.PrWatch`), a fix that leaves the head unchanged is `no_progress` (`PrFixExhausted`), fast-forward-only pushes (never force), PR text and CI logs fenced as untrusted, auto-fix off until the project sets `pr_auto_fix`.
- **Env contract.** Server: `FOREMAN_API_TOKEN`, `FOREMAN_API_ALLOW_INSECURE_LOCAL`, `FOREMAN_PR_WATCHER_ENABLED`, `FOREMAN_PR_MONITOR_ENABLED`, `FOREMAN_GITHUB_WEBHOOK_SECRET`, `FOREMAN_SCHEDULE_TICKER_ENABLED`, `FOREMAN_NOTIFY_WEBHOOK_URL` (+ `FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP`, `FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS`: the exact string `true` lets that webhook take an http URL or a loopback/private-network host, §21), `FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN` + `FOREMAN_NOTIFY_TELEGRAM_CHAT_ID` (both or boot aborts) and `FOREMAN_NOTIFY_SLACK_WEBHOOK_URL` (https, public host, no opt-out); `config/runtime.exs` allows at most ONE provider's variables (a mix aborts boot naming the variables, never their values). CLI: `FOREMAN_API_URL`, `FOREMAN_API_TOKEN`. Agents: `FOREMAN_RUN_ID`, `FOREMAN_PROJECT_ID`, `FOREMAN_ARTIFACT_PATH`, `FOREMAN_LIBRARY_PATH` (non-empty library only). The `FOREMAN_*` namespace is reserved: a project `config.env` key in it fails the phase launch.
- **UNVERIFIED live.** Verified live since the spikes: GitHub webhooks, force-push handling, check re-run, conflict resolution and review comments on a real private repo (`docs/acceptance/github-live-run.md`); the workspace Fix CI / Address comments / Resolve conflicts / Create PR buttons on real PRs (unresolved review threads read live), the `pr_auto_fix` policy off/on/bounded and GitHub's refusal of an operator merge (`docs/acceptance/live-github-protection-ui-autofix.md`; a PR opened by Create PR enters the merge gate: `run.pr.create` signals `run.pr.ready`); operator merge under real branch protection (a required review and required status checks refuse it with GitHub's text verbatim, the same approval and head pin merges once every rule is met; the squash results had one parent, but a refusal by `required_linear_history` itself was not tested; a temporary public window of a scratch repository after a content scan of every branch and PR ref: `docs/acceptance/live-github-branch-protection.md`); a PR fix thread resuming its run's claude session on a real PR (haiku, host sandbox, Fix CI: `docs/acceptance/live-claude-prfix-resume.md`); and Claude coordinator, thread, reviewer, in-flight approval and steering paths for short haiku sessions (`docs/acceptance/parity-gaps-live-run.md` and the other `docs/acceptance/*-live-run.md` files). A push after merge approval was observed live only on the build before foreman-ehxy6 (#650), where it stranded the PR; since #650 it voids the approval and holds the gate again, covered by tests and not re-run live. Still UNVERIFIED: the refusal of a merge by `required_linear_history` itself, Claude session resume in the cases not run live (models other than haiku, the fix thread of a `prompt`-mode or session-less run, the Address comments and Resolve conflicts kinds with claude, a docker-sandbox fix thread), the phase-wide approval grant (spike S2), Telegram and Slack delivery (deferred by the user) and in-container network blocking. Document them as unverified until exercised against the real service. Multi-repo (E12) is on `main` (on by default, `config :foreman_server, :multi_repo, runs: true`). Verdicts and bead ids: `docs/acceptance/parity-audit.md`.
