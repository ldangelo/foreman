# Workflow catalog and worktree contract (§11–§12)

> Moved verbatim from `CLAUDE.md`. Section numbers are unchanged; `CLAUDE.md` names the file holding each `§N`, so a reference to a section that is not in this file resolves there.

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

Every **pi** phase worker additionally gets `PI_SUBAGENT_CHILD=1` in its
environment, whether or not the worktree is enabled, so a machine-wide pi
extension cannot replace the model Foreman resolved for the phase (see
`docs/user-guide.md` §7.3).

**Project environment (E4).** `ForemanServer.ProjectEnvironment.resolve/2` is the
single producer of a project's agent env and redaction list; `RunExecutor`,
`Overwatch` and the follow-up run path (`RunExecutor`) all call it, never `config.env` directly.
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
verbatim (`WorkerLogPolicy.redact/2` replaces the longest value first, whatever the caller's list order); `PrFixRequested` events stored before PR #761 are not rewritten (the operator's note is value-redacted in `CommandGateway` now, and `TurnRunner`'s failed-turn and action-reason log lines are redacted before they are cut); an unreadable secret store degrades redaction to the other values; redaction can lengthen a note near the 2000-character cap into `invalid_note`. Observed live 2026-10-30 (`scripts/e2e/redaction_value_live.sh`, `foreman-mw5rz`, fixed by PR #775 and re-verified live 2026-10-31): the server's debug request log (Phoenix `Parameters:` and LiveView `HANDLE EVENT` lines, stdout and `foreman-server.log`) carried the arguments of an MCP `tools/call` and the text of a chat request before redaction; `config :phoenix, :filter_parameters` now hides the free-text keys, the MCP `params` envelope and `token` by key name, and `Observability.SecretValueLogFilter` (a `:logger` primary filter plus `Refresher`, `config :foreman_server, :secret_log_filter`; `foreman-25sqf.1.1`) redacts every stored secret value of 8+ characters from every log event whatever key carries it (message only, not metadata; a hand-edited secret file is covered after one refresh interval); every other durable surface searched was clean (`docs/acceptance/e2e-live-verify-2026-10-30.md`). New text
persisted about a project MUST use `secrets/1` (through `Coordinator.Redact`), not
`WorkerLogPolicy.redact/1` alone.
Secret VALUES live only in `ForemanServer.SecretStore` (file backend, dir from
`config :foreman_server, :secret_store, dir:`; tests point it at a tmp dir) and
must never enter an event, command payload, log, projection or API response:
`ProjectSecrets.set/4` stores the value then dispatches the system-only
`project.secret.set` carrying name+version. `config.environment` (vars,
`setup_script`, network) is written only by the operator command
`project.environment.set`; `project.update`/`register` reject the key. The setup
script (`ProjectSetup`, run via `Exec.HostCommand` in its own process group)
runs once after worktree creation; network policy
(`Exec.NetworkPolicy`) is enforced on docker runs only (`sandbox: docker`, §27); a host
(`RunExecutor`) run whose project carries a non-default `network` policy is
refused at kickoff (§13.2).

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
  Registry, not cwd discovery; the database path is required for Beads only: Go CLI
  project create/update requires `--task-provider-database-path` when
  `--task-provider=beads`, and rejects it for `--task-provider=kata`, whose binding is
  `config.cwd`, see §13.3) and
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
