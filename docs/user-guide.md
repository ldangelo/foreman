# Agent runtime — operator & developer guide

This guide explains how to operate and extend the `ForemanServer.AgentRuntime`
subsystem. It documents behavior implemented by
TRD-2026-6af02293 (TRD-001 through TRD-009). Anything speculative
about future slices is intentionally omitted.

For invariant developer conventions (process layering, error shapes,
telemetry contract) see [`../CLAUDE.md`](../CLAUDE.md). This file
focuses on configuration keys, defaults, and the adapter-extension
recipe.

## 1. Enabling the runtime

```elixir
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.PiAdapter]
```

By default `packages/foreman_server/config/config.exs` already registers
`ForemanServer.AgentRuntime.Adapters.PiAdapter` under
`:agent_runtime.adapters` whenever the runtime is enabled, so an
out-of-the-box `MIX_ENV=dev` (or `prod`) boot has the local `pi` backend
available without further configuration. `PiAdapter.available?/0`
self-gates on `System.find_executable/1` returning a path for the
configured executable (default `"pi"`), so the registration is safe to
leave in place even on hosts where the binary is missing. When
`available?/0` returns `false` Pi is silently excluded from routing in
`:automatic` / `:policy` modes (and `:manual` calls to it return
`:backend_unavailable`); the caller observes
`{:error, :no_available_backend}` only when **no** eligible adapter is
available for the request. The
test environment (`config/test.exs`) deliberately overrides
`adapters: []` so individual adapter tests can opt in explicitly and
stay isolated from production wiring.


When `enabled: true`, `ForemanServer.Application` starts
`ForemanServer.AgentRuntime.Supervisor`, which boots the catalog and
the dynamic invocation supervisor. Setting `enabled: false` (or
omitting the key) means the supervisor never starts and `execute/3`
is the only entry point with no live catalog — manual `register/1`
calls succeed against the registered modules but the supervisorless
catalog is empty.

The runtime configuration is keyed under `:foreman_server,
:agent_runtime`. The full set of supported keys is below. Adding a
key not listed here is treated as a feature request, not a bug fix.

## 2. Configuration keys (canonical list)

| Key | Default | Purpose |
|---|---|---|
| `:enabled` | `false` | Whether the runtime supervisor starts at boot. |
| `:adapters` | `[]` | Modules registered with the catalog at boot. Each must `use` or implement `BackendAdapter`. |
| `:failure_policies` | `%{}` | Map of `task_type => %{fallback?, timeout_ms?, max_attempts?}` overrides. |
| `:default_timeout_ms` | `60_000` | Global default `timeout_ms` for `FailurePolicy.resolve/2` when no per-call or per-task override applies. |

Per-adapter config:

| Key | Default | Purpose |
|---|---|---|
| `:foreman_server, ForemanServer.AgentRuntime.Adapters.PiAdapter, :executable` | `"pi"` | Binary or absolute path. Bare names are resolved via `System.find_executable/1`. |
| `:foreman_server, ForemanServer.AgentRuntime.Adapters.PiAdapter, :timeout_ms` | `60_000` | Adapter-side execution deadline enforced in the receive loop. |

> Each key maps to exactly one implementation path. If a key is
> missing, the documented default applies. If a key value is invalid,
> startup or registration returns a typed error.

## 3. Per-task failure policies

```elixir
config :foreman_server, :agent_runtime,
  default_timeout_ms: 60_000,
  failure_policies: %{
    code_review:   %{fallback: true},
    long_running:  %{timeout_ms: 5 * 60_000, max_attempts: 3, fallback: true},
    cheap_lookup:  %{timeout_ms: 5_000}
  }
```

At each call, `ForemanServer.AgentRuntime.FailurePolicy.resolve/2`
resolves in this precedence (high → low):

1. **Per-call `opts`** — only keys present in the call override.
2. **Per-task-type** from `failure_policies[task_type]`.
3. **Built-in defaults** (constants are not configurable):
   `fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: <default_timeout_ms>`.

A few invariants:

- `:fail_fast` is **always** `true` in the resolved map. The literal
  matches the TRD default verbatim; the façade never overrides it.
- When the resolved `:fallback` is `true` and no layer supplied
  `:max_attempts`, the resolved `:max_attempts` is `2`.
- `:max_attempts` bounds total attempts across fallback, not retries
  per backend.

## 4. Routing strategies

`execute/3` accepts three strategies via `:strategy`:

| Strategy | Required opt | Behavior |
|---|---|---|
| `:manual` | `:backend` | Returns `:backend_not_found` or `:backend_unavailable` if the named backend is missing or unavailable. Never substitutes. |
| `:automatic` | `:task_type` | Filters `supported_contexts` → `available?/0`, sorts by `(cost_per_call, typical_latency_ms, registration order)`, no randomness. |
| `:policy` | `:task_type`, `:policy_module` | Delegates to `policy_module.route(task_type, capabilities)`. Returns `:backend_not_found` for unregistered selections; skips unavailable ones when fallback is on. |

Default strategy is `:manual`. If `:backend` is omitted under
`:manual`, the call returns `{:error, :backend_not_found}`.

## 5. Public result shape

`execute/3` returns one of:

```elixir
{:ok, output_text}
| {:error, :no_available_backend}
| {:error, :backend_not_found}
| {:error, :backend_unavailable}
| {:error, :timeout}
| {:error, {:non_zero_exit, exit_status :: non_neg_integer()}}
| {:error, :all_backends_failed, %{attempts: [attempt_result()]}}
| {:error, term()}
```

The successful branch **never** contains a backend name. Adapter-
private metadata is captured only in the completion telemetry event
under `:adapter_metadata`.

## 6. Telemetry

The runtime emits a single completion event per call on
`[:foreman, :agent_runtime, :invocation, :complete]`. See
[`../CLAUDE.md`](../CLAUDE.md) §7 for the exact measurements and
metadata shape. The event is privacy-safe by construction: every
metadata key is the result of a whitelist projection against the
adapter result shape, so adapters cannot accidentally leak prompt
text, secrets, or full output bodies through metadata.

Handlers attach via `:telemetry.attach/4`; one is enough. The test
suite attaches handlers per test via `capture_completion_events/1`
and detaches in `after`.

## 7. Workflow templates and prompts

Workflow manifests and prompt bodies live under the runtime root
(`~/.foreman/workflows` by default — `AssetCatalog.default/0` is
hardcoded; tests and slice binaries that need a different root must
call `AssetCatalog.new/1` and pass it to
`ForemanServer.Workflow.Catalog.start_link/1` explicitly).

- **Auto-install** — at startup, if the root contains no
  `*.yaml` manifests (a populated `prompts/` directory does **not**
  suppress the install), the catalog copies the bundled templates
  from the application `priv/`. If a manifest is already present the
  installer is skipped; note that the installer uses `File.cp/2` and
  `File.write/2` and will overwrite any bundled-name file on disk, so
  re-installing over a populated root is destructive — keep custom
  templates under their own filenames.
- **Hot reload** — the catalog polls the root on a short interval
  (default 2 s, override via
  `Application.put_env(:foreman_server, :workflow_catalog_poll_ms, ms)`)
  and replaces any manifest or prompt whose content or mtime changed.
  `RunExecutor.read_phase_prompt/2` and `Approval.prepare/2` read
  through the catalog, so a prompt or manifest edit is visible to the
  next consumer after the next reload pass — typically within the
  configured poll interval (default 2 s), or immediately after
  `Catalog.reload/0`.
- **Manual reload** — call `ForemanServer.Workflow.Catalog.reload/0`
  from IEx (or any module) to force an immediate pass without
  waiting for the poll.
- **Telemetry** — every install, load, reload, and removal emits
  `[:foreman_server, :workflow, ...]` events. Attach handlers to
  observe the catalog in production.

## 8. Adding a new adapter (developer workflow)

The minimum to add an optional adapter:

1. **Define the module**

   ```elixir
   defmodule MyApp.MyAdapter do
     use ForemanServer.AgentRuntime.BackendAdapter

     @impl true
     def name, do: :my_adapter

     @impl true
     def capabilities do
       %{
         type: :remote,
         strengths: [:long_context],
         weaknesses: [],
         supported_contexts: [:code_review],
         cost_per_call: 0.01,
         typical_latency_ms: 4_000
       }
     end

     @impl true
     def available?, do: true

     @impl true
     def execute(%{prompt: prompt, context: _ctx}, _opts) do
       {:ok, MyApp.Client.complete(prompt), %{}}
     end
   end
   ```

2. **Wire it in config**

   ```elixir
   config :foreman_server, :agent_runtime,
     enabled: true,
     adapters: [MyApp.MyAdapter]
   ```

   Or register at boot:
   `ForemanServer.AgentRuntime.register(MyApp.MyAdapter)`.

3. **Verify registration succeeds.** Validation runs on every
   registration; missing required capabilities or wrong field types
   return `{:error, reason}` and **nothing** is inserted into the
   catalog. The application logs a startup-time error if a configured
   adapter is invalid.

### Required callbacks

```elixir
@callback name() :: atom()
@callback capabilities() :: map()      # validated against Capabilities.input/0
@callback available?() :: boolean()
@callback execute(%{prompt: String.t(), context: map()}, keyword()) ::
            {:ok, String.t(), map()} | {:error, term()}
```

### Required capability fields

```elixir
%{
  required(:type) => atom(),
  required(:strengths) => [atom()],
  required(:weaknesses) => [atom()],
  required(:supported_contexts) => [atom()],
  optional(:cost_per_call) => number(),
  optional(:typical_latency_ms) => non_neg_integer()
}
```

A missing or wrong-typed **required** field causes registration to
fail with `{:error, ...}`. `:cost_per_call` and `:typical_latency_ms`
are optional; missing values sort after declared ones in automatic
routing.

### Availability semantics

`available?/0` is called on every `execute/3`. An adapter that
returns `false` is **silently skipped** in `:automatic` and `:policy`
modes; under `:manual`, the call returns `:backend_unavailable`.
Implementations should consult local credentials / binary paths
without making a network call.

### Test expectations (ExUnit coverage for a new adapter)

- happy path: adapter returns `{:ok, text, %{}}`; the public
  `execute/3` returns `{:ok, text}` and no backend name.
- canonical failure: adapter returns `{:error, reason}`; the
  public tuple carries the same `reason` (or a typed fallback
  variant such as `:all_backends_failed`).
- unavailable: `available?/0` returns `false`; the catalog omits it
  from automatic/policy candidates and manual calls return
  `:backend_unavailable`.
- payload isolation: the public result tuple contains no backend
  identifier, prompt, or adapter-internal text.

See `packages/foreman_server/test/foreman_server/agent_runtime/` for
frozen examples of all four.

## 9. The Pi adapter in practice

The provided `PiAdapter` shells out to the local `pi` binary:

- Defaults to `"pi"` (PATH-resolved). Set
  `:foreman_server, ForemanServer.AgentRuntime.Adapters.PiAdapter, :executable`
  to an absolute path.
- Enforces `:timeout_ms` (default `60_000`) inside its own receive
  loop and returns `{:error, :timeout}` on expiry.
- Cleans up its temporary request file/directory on every resolved
  outcome. On untrappable process death the request file/dir may
  leak — this is a documented v1 limitation, not a regression.

## 10. Quick troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `{:error, :no_available_backend}` | Empty `:adapters` config or all `available?/0` are `false` | Add at least one adapter; ensure its `available?/0` returns `true`. |
| `{:error, :backend_not_found}` with `:manual` | Mistyped `:backend` opt or registration didn't run | Check `ForemanServer.AgentRuntime.register/1` calls at boot, or list configured `adapters:` in config. |
| `{:error, :backend_unavailable}` with `:manual` | The chosen backend's `available?/0` is `false` | Confirm the underlying binary/credentials are present; the call is intentional and never substitutes another backend. |
| `{:error, :all_backends_failed, ...}` | Bounded fallback exhausted | Inspect `attempts:` list — order matches `attempted_backends`. Tune `:failure_policies` or `:max_attempts`. |
| Telemetry duplicate events | Handler attached multiple times | Detach in `after`; one handler per test/per subscription is enough. |

## 11. Task-provider enablement

The Go/Elixir CQRS slice adds a separate `:task_provider` boundary for
projects that want Foreman to drive Beads issue state alongside the run
lifecycle.

Global registration lives in application config:

```elixir
config :foreman_server, :task_provider,
  actor: "foreman-runner",
  accepted_contract_versions: ["br.capabilities.v1"],
  providers: [ForemanServer.TaskProviders.BeadsAdapter]
```

Each project opts in explicitly with a per-project `task_provider`
block:

```elixir
%{
  project_id: "proj-123",
  path: "/srv/foreman/proj-123",
  task_provider: %{
    provider: ForemanServer.TaskProviders.BeadsAdapter,
    config: %{
      database_path: "/srv/beads/proj-123.sqlite3"
    }
  }
}
```

The `database_path` must be absolute. `ProjectRegistered` /
`ProjectUpdated` normalize it with `Path.expand/1` and reject relative
paths before any `br` invocation is attempted. Projects with no
`task_provider` block continue to run without this boundary.

Projects whose `task_provider` capabilities advertise `:create`
(as reported by `br capabilities --json` and validated by the
projector against the contract schema) participate in a
**pre-append synchronous bead-creation hook**. For a `task.create`
command:

1. `Aggregate.Actor.handle_call({:command, …})` produces the
   stage-1 `TaskCreated` event spec via
   `aggregate.handle_command/2`.
2. The actor calls `TaskProvider.Registry.route(:create, …)` and,
   when a provider is registered, invokes `provider.create/2`
   synchronously. The resulting bead id is cached against the
   command id in `state.in_flight_beads` before any append occurs.
3. The actor re-runs `aggregate.handle_command/2` with the bead id
   populated as `payload.external_id`; the persisted event then
   records the bead id on `TaskCreated.external_id`.
4. Only after the enriched event spec is built does the actor
   append to the event store.

If `provider.create/2` itself fails, no append happens and no bead
is created — the error propagates back to the caller as the
command's rejection. If the cache is populated (stage 2 succeeded)
but a later stage rejects — a re-decision returns `{:error, …}`, or
the append-conflict retry loop exhausts its attempts — the actor
runs compensation via `BeadsAdapter.complete/3` with a canonical
`transition_comment`. The close is **best-effort** — `complete/3`
itself can fail (the actor emits
`[:foreman_server, :task_provider, :beads, :create, :compensate_failure]`
telemetry and clears the cache entry either way to prevent
double-close), so the cached bead is closed before the error
returns to the caller on the characterized success path but may
remain open if the close itself fails. Other append-failure modes
outside the conflict-retry path are not characterized here.
Projects that do not advertise `:create` skip the hook entirely;
`TaskCreated` records `external_id: nil`, and downstream tooling
distinguishes the two cases by reading the task projection via
`foreman task get`.

Runtime ownership is split deliberately:

- `RunExecutor` drives `claim/3`, `complete/3`, and `fail/3`.
- `Workflow.BootReconciliation` drives orphan-reopen on boot.
- `set_priority/3` and `add_dependency/3` exist at the adapter
  boundary, but this slice does not introduce an operator CLI surface
  for them.

### Worktree-create orphan recovery on boot

`Workflow.BootReconciliation` reconciles worktree-create orphans —
operations whose Git side effect succeeded but whose
`vcs.worktree.create` command dispatch failed before the
`WorktreeCreated` event could be persisted. The on-disk worktree
exists but no `WorktreeCreated` projection records normal
provisioning. On every boot scan, for each entry:

1. **Skips silently** if the bound run is still in progress — the
   worktree may still be in use.
2. **Preserves** the entry and emits
   `[:foreman_server, :vcs, :worktree, :orphan_preserved]` with
   measurements `%{operation_id: op_id}` and metadata
   `%{run_id: …, phase_id: …, worktree_path: …, reason: :dirty}`
   if the worktree directory has local modifications (operator files
   at risk — never auto-deleted).
3. **Preserves** the entry with the same event and
   `reason: :active_workers` if live workers still reference the run.
4. **Retries the cleanup** via `Worktree.clean_orphan/1` (removes the
   on-disk worktree) and dispatches the
   `vcs.worktree.create.orphan_resolve` command. Successful recovery
   removes the orphan entry and emits no telemetry. Cleanup failure
   preserves the entry with `reason: :clean_failed`; resolve
   dispatch failure preserves the entry with
   `reason: :resolve_dispatch_failed`.
Operators can subscribe to
`[:foreman_server, :vcs, :worktree, :orphan_preserved]` to monitor
recovery outcomes. The `worktree_path` field identifies the on-disk
target; the `reason` atom is one of `:dirty`, `:active_workers`,
`:clean_failed`, or `:resolve_dispatch_failed`, and explains why a
particular orphan was preserved. There is no CLI surface for these
events — recovery is driven entirely by `BootReconciliation` on boot.

### Flag-gated supervisor children (opt-in Bi-directional sync)

The bi-directional sync with Beads (`BeadsWatcher` + `BeadsOrphanJanitor`)
is **opt-in per supervisor**. Both supervisors are flag-gated siblings of
the existing `JsonSchemaCache` / `ProjectProviderProjector` pattern. With
both flags `false`, the supervisors never start and a project's Beads
JSONL is never tailed.

| Config key | Default | Effect when `true` |
|---|---|---|
| `:foreman_server, :start_beads_watcher?` | `false` | `ForemanServer.TaskProviders.BeadsWatcherSupervisor` is added under `ForemanServer.Application`; the supervisor reconciles its child set from the projector (`spawn_project_children/2`) on every project register / unregister. With this flag on but `:start_beads_orphan_janitor?` off, the watcher tails every registered project's JSONL but orphaned foreman-issued beads stay open. |
| `:foreman_server, :start_beads_orphan_janitor?` | `false` | `ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor` is added under `ForemanServer.Application`; the supervisor spawns a scanner per registered project that closes stranded foreman-issued beads after the grace window. With this flag on but `:start_beads_watcher?` off, a stranded bead stays stranded — there is no inbound path to issue the matching Foreman task. |

Operational notes:

- Operators are expected to opt into **both** flags for production. The
  flags are independent so that staged rollouts can enable one direction
  at a time; an asymmetric combination (watcher-only or janitor-only)
  leaves stranded foreman-issued beads accumulating in Beads without a
  matching Foreman task. Run `foreman doctor task_provider` to inspect
  each project's Beads-side health (the supervisor flag state itself is
  reported by the application supervisor, not by the doctor).
- `config/config.exs` and `config/test.exs` both set both flags to
  `false` — the same default the test suite relies on. For production
  override these via `Application.put_env/3` at boot (or via a release
  config that uses `REPLACE_OS_VARS` / runtime env var substitution)
  before enabling production sync. Leave them `false` when running
  tests to avoid spawning per-project workers.
- The Projector (`ForemanServer.TaskProvider.ProjectProviderProjector`)
  checks both flags before reconciling: with both `false`,
  `register_or_unregister_project/2` no-ops and never invokes the
  supervisors, regardless of how many projects are registered.

## 12. `foreman doctor task_provider`

Run the operator-facing command:

```
foreman doctor task_provider
```

The command emits one JSON object per task-provider project. Each report
includes:

- `project_id`
- `provider_id`
- `contract_version`
- `br_version`
- `capabilities` (`br capabilities --json`)
- `sample_ready` (`br ready --limit 1 --json`)
- `schema_validation_failures`
- `janitor_enabled` — whether the server-level flag
  `:start_beads_orphan_janitor?` is currently set in the merged
  runtime config. The doctor reads this via `Application.get_env/3`,
  independent of supervisor liveness; a true value here does not
  imply the supervisor is currently running.

- `janitor_running` — boolean. `true` only when
  `BeadsOrphanJanitorSupervisor` is registered AND a janitor child
  exists for this `project_id`. `false` when the supervisor
  process is absent (e.g. started with `--no-start`) or no child
  has been started for the project.
- `orphan_backlog` — the janitor's last scan snapshot, `nil` until
  the first scan completes after registration. When present, an
  8-field map with keys `lines_processed`, `lines_tagged`,
  `lines_untagged`, `lines_malformed`, `lines_retained`,
  `lines_closed`, `lines_age_young`, `lines_no_linked_at`. This is
  a CQRS read of the cached snapshot maintained by the janitor's
  own scan loop — the doctor MUST NOT call
  `BeadsOrphanJanitor.run_scan/2` itself. The snapshot lag depends
  on the scan interval configured for the project.

Exit behavior is strict:

- exit 0 / `:ok` when every reported project is healthy
- exit 1 when any reported project is unhealthy

Unhealthy reports expose only the allowlisted error fields:
`code`, `message`, `hint`, `exit_code`, `stderr_byte_count`, and
`redacted_fields`. Raw `stderr` is never printed, even for
`DATABASE_NOT_FOUND`.

## 13. Project CRUD from the CLI

The project CRUD surface is intentionally small: all mutations go
through `POST /api/commands`, while reads come from project
projections.

### Create a project

Register a project and opt it into a task provider:

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads
```

Use `--format=json` when you want the accepted command envelope back
instead of the summary line.

### Get one project

Read the current projection for a single project:

```
foreman project get project-123
```

Add `--format=json` to print the raw API response.

### Update a project

Update the task-provider assignment for an existing project:

```
foreman project update --task-provider beads project-123
```

The CLI sends `project.update` through `/api/commands`; it does not
write directly to the event store or projections.

### Delete a project

Archive a project:

```
foreman project delete project-123
```

This command is a soft-delete, not a hard purge. Archived projects stay
queryable via the read model. If active runs still exist, the server
rejects the archive; rerun with `--force` to print the blocking run ids
to stderr before the CLI exits non-zero.

### List projects

List visible projects:

```
foreman project list
```

By default the CLI prints a table with `ID`, `PATH`, `ARCHIVED`,
`REGISTERED`, and `VERSION`. Add `--include-archived` to include
archived rows, `--format=json` for a JSON array, or `--format=ndjson`
for one JSON object per line.

### Performance and scaling note

The server caps project-list responses at 1000 rows per request. When
that cap is hit, the CLI prints a truncation warning and the HTTP
response carries `X-Total-Count` with the full matching count so you can
measure how much data was omitted.

## 14. The plan workflow

The `plan` workflow turns a single task into a two-phase Ensemble run that
produces a draft PRD and a draft TRD. Both phases are `command:` phases,
so the agent runtime forwards a slash command at byte zero (no `# Prompt`
header) and Ensemble handles the rest of the artifact flow.

### Manifest shape

`plan.yaml` declares two phases; both require a planning context key
to exist before they run:

```yaml
name: plan
description: Create draft product and technical requirements for later refinement.
phases:
  - name: create-prd
    command: "/skill:ensemble-full-create-prd --foreman"
    requiredFile: planning.prd_path
  - name: create-trd
    command: "/skill:ensemble-full-create-trd --foreman"
    requiredFile: planning.trd_path
```

- `command:` — non-empty string beginning with `/`. Passes through to
  the Pi adapter as the prompt body, so the skill sees a slash command
  at byte zero.
- `requiredFile:` (singular) — dotted scalar in the planning context
  (e.g. `planning.prd_path`). The phase gate fails with
  `:required_file_missing` if the resolved path does not exist on disk
  when the phase starts.

### What the plan phase receives

The runtime builds a `PlanContext` for plan tasks and merges it into
the standard phase context. The agent's `request.context` map carries:

- `working_directory` — the project's registered path.
- `planning.prd_path` / `planning.trd_path` — absolute paths Ensemble
  must write to, derived from the project path, document year
  (UTC of the frozen `approved_at`), and a slug from the task title.
- `planning.correlation_id` — first 8 lowercase hex characters of the
  run id (e.g. `720139c8`).
- `planning.document_year` — UTC year of the frozen `approved_at`.
- `planning.slug` — lowercase ASCII slug from the task title (≤48 chars).

If the project path does not exist on disk, `PlanContext.build/1`
returns `{:ok, _}` with deterministic paths but the gate will still
fire `:required_file_missing` when the phase actually starts.

### Failure mode

When `required_file` points to a file that does not exist, the phase
is marked `failed` with `failure_reason` containing
`{:required_file_missing, planning_key, resolved_path}`. Operators see
the inspected failure in the phase projection and can fix the upstream
artifact or the project registration before retrying.

### Where the manifest lives

The bundled `plan.yaml` ships under
`packages/foreman_server/priv/defaults/workflows/`. Re-run
`foreman init --force` to refresh the installed copy at
`~/.foreman/workflows/plan.yaml` after a Foreman upgrade.

## 15. The implement-trd and implement-trd-beads workflows

Two bundled manifests drive TRD execution under Foreman-managed
execution via the `--foreman` flag:

- `implement-trd.yaml` — single-task TRD implementation via the
  Ensemble `ensemble-full-implement-trd` skill.
- `implement-trd-beads.yaml` — Beads-backed two-task flow that
  scaffolds a Beads hierarchy from the TRD and then executes it.

Both manifests are bundled under
`packages/foreman_server/priv/defaults/workflows/`. Re-run
`foreman init --force` to refresh the installed copies at
`~/.foreman/workflows/implement-trd.yaml` and
`~/.foreman/workflows/implement-trd-beads.yaml` after a Foreman
upgrade.

### Manifest shape
Both manifests declare a single phase that owns its own worktree.
The Beads-backed variant reads the flat `trd_path` key resolved
from the task's `implementation` block; the planning-context
variant reads the nested `planning.trd_path` key written by the
upstream plan phase:

```yaml
# Beads-backed: implementation context exposes trd_path flat.
name: implement-trd-beads
description: Implement a Technical Requirements Document via the Beads-backed ensemble implement-trd-beads skill under Foreman-managed execution.
phases:
  - name: implement-trd-beads
    command: "/skill:ensemble-full-implement-trd-beads {{implementation.trd_path_argument}} --foreman"
    worktree:
      enabled: true
      base: "{{implementation.source_revision}}"
      branch: foreman/{run_id}/{phase}
      cleanup: always
---
# Planning-context: planning.trd_path written by the plan phase.
name: implement-trd
description: Implement a Technical Requirements Document via the ensemble implement-trd skill under Foreman-managed execution.
phases:
  - name: implement-trd
    command: "/skill:ensemble-full-implement-trd {{implementation.trd_path_argument}} --foreman"
    worktree:
      enabled: true
      base: "{{implementation.source_revision}}"
      branch: foreman/{run_id}/{phase}
      cleanup: always
```

- `command:` — non-empty slash command. The
  `{{implementation.trd_path_argument}}` placeholder is substituted at
  approval time with the JSON-quoted project-relative path to the TRD
  so the skill receives a shell-safe argument. The bundled manifests
  intentionally omit `requiredFile`: the TRD is verified as a tracked
  Git blob at approval time via `ImplementationContext`, not as a
  post-command file gate.

- `worktree:` — declares a per-phase worktree owned by Foreman.
  - `enabled: true` activates the worktree lifecycle.
  - `base: "{{implementation.source_revision}}"` is substituted at
    approval time with the project's frozen source revision. The human
    review surfaces the exact base ref Foreman will execute from.
  - `branch: foreman/{run_id}/{phase}` is substituted at runtime
    with the run and phase ids so each phase gets its own branch.
  - The leaf directory name is derived from `phase.name`; the final
    worktree path is
    `~/.foreman/worktrees/<project_id>/<run_id>/<phase.name>`. The path
    is containment-checked against that root at runtime — template
    payloads that smuggle `..` or render to absolute paths are rejected
    before `git worktree add` runs.
  - `cleanup: always` removes the worktree after the phase completes
    or fails.

### Approval-time rendering

Foreman renders the strict fields at approval time so the human
review surfaces the exact command and base ref that the executor
will run. The renderer substitutes:

- `{{implementation.trd_path_argument}}` in `command:` with the
  JSON-quoted project-relative TRD path.
- `{{implementation.source_revision}}` in `worktree.base` with the
  project's frozen source revision.

Other placeholders (`{run_id}`, `{phase}`) remain literal until run
time so the approval payload is deterministic.

### Runtime artifact-template rendering

Prompt-phase `artifact_template` paths are rendered at runtime (not at
approval time) so each phase knows its own run id and reports
directory. The renderer substitutes, in this order:

- `{run.id}` → the active run id.
- `{task.id}` → the Foreman internal task id
  (`state.task.task_id`, e.g. `foreman-mcp-trd`). Foreman's operator
  API exposes `task_id` as the primary identifier and forbids
  `external_id` on `task.create`; provider-facing lifecycle calls
  separately route through the `external_id` registered against the
  task (see `run_executor_test.exs` "provider-facing lifecycle calls
  use the task's external_id, not the Foreman task_id"). `task_id_of/1`
  in `RunExecutor` returns whichever of these the run-time state
  carries as `state.task.task_id`.
- `{task.projectReportsDir}` and `{reportDir}` → the canonical
  `<working_directory>/docs/reports/foreman-<task.id>` path Foreman
  writes per-phase reports to (suffixed with the same
  `state.task.task_id`).

When `artifact_template` resolves to `nil` or an empty string the
phase falls back to `default_path/2`; when it is a binary the path is
expanded against the running state. No other substitutions are
performed in `artifact_template` — required-file gates and slash
commands remain literal at this layer.

### Environment variables

Foreman auto-injects the following environment variables into the
phase execution when the worktree is enabled:

- `FOREMAN_WORKTREE=1` — flag the skill is operating inside a
  Foreman-managed worktree.
- `FOREMAN_RUN_ID` — the run id.
- `FOREMAN_WORKTREE_PATH` — absolute path to the worktree.
- `FOREMAN_EXPECTED_BRANCH` — the rendered branch
  (`foreman/{run_id}/{phase}`).
- `FOREMAN_SOURCE_REVISION` — the rendered base revision.
- `FOREMAN_IMPLEMENTATION_KEY` — opaque key tying the run to its
  approval.
- `BEADS_DB` — set only by `implement-trd-beads` when the planning
  context provides a Beads database path.
- `TRD_SCOPE` — set only by `implement-trd-beads` when the planning
  context provides a TRD scope.

`FOREMAN_EXPECTED_BASE` is **not** injected; the base is resolved
lazily at completion time to honor any pushes that landed during the
phase.

### Task vs. workflow separation

The provider-facing task type (for example `--task-type feature`,
`--task-type bug`, `--task-type chore`) is independent of the
implementation workflow the run will execute. `--workflow-type`
(`implement-trd` or `implement-trd-beads`) selects which bundled
manifest Foreman resolves at approval. Approval precedence is
`workflow_type || task_type || default_task_type`; existing tasks and
manifests without `workflow_type` keep their prior behavior.

### Tracked-TRD requirement

`--trd-path` must point to a **tracked regular blob** in the
registered project repository at the frozen source revision.
`ForemanServer.Workflow.ImplementationContext.build/1` resolves
`git rev-parse HEAD` and rejects TRDs that are untracked, in the
working copy only, directories, symlinks, or reachable only via
traversal. The frozen context persists the exact relative path and
SHA; later movement of `HEAD` does not change the implementation
key or the path the phase reads. Idempotent re-approval reuses the
persisted snapshot.

### Foreman vs. skill ownership

Worktrees are exclusively Foreman's responsibility: it picks the
pinned base revision, creates the unique branch and worktree before
the phase, sets the phase cwd, records durable lifecycle events,
removes clean worktrees on terminal phases, and reconciles orphans
after restart. `--foreman` tells the Ensemble skill that Foreman has
already provisioned the branch and worktree; the skill verifies the
trusted cwd/branch/revision markers (see "Environment variables"
above) and must not create, switch, append, or stack branches. There
is no skill-owned worktree fallback — failed Foreman provisioning is
a hard error, not a fallback to the controller checkout.

### Same-TRD exclusion

Foreman derives `implementation_key = SHA256(project_id <> "\0" <>
normalized_trd_path)` at approval and reserves it through
`ProjectRunReserved`. While a run holding that key is active, any
second `run.start` for the same normalized project/TRD is rejected
with `{:implementation_already_active, implementation_key,
existing_run_id}` before any worktree side effect. Distinct keys
remain eligible up to the configured project run limit (100 active
reservations per project — see REQ-022). The reservation is released
through the same terminal/rejection paths that release the existing
`run_id` reservation, so a retry can re-implement the same TRD after
the prior run reaches a truthful terminal state. The implementation
key is server-derived and cannot be overridden by operator payload or
phase YAML context.

### Beads scope and database rules

For `--workflow-type implement-trd-beads`, Foreman freezes two
additional reserved fields at approval:

- `task_provider.config.database_path` — the absolute path to the
  canonical project Beads database, obtained from
  `ForemanServer.TaskProviders.TaskProvider.Registry` rather than
  rediscovered from the worktree. The worktree must not bring its own
  `.beads/` into the phase.
- `TRD_SCOPE` — `<trd-slug>-<first-12-of-implementation_key>`.
  Every `br`/`bv` invocation the Beads skill issues must pass
  `BEADS_DB` and `TRD_SCOPE` explicitly; cwd discovery is forbidden.
  Scaffold title prefixes are `[trd:<TRD_SCOPE>]` and every
  resume/status/ready/robot-plan candidate is filtered by the exact
  scope before extracting `TRD-NNN` IDs, so two paths with the same
  filename or repeated task IDs cannot claim each other's beads.

**Scope limitation — what the lease does NOT cover.** The
`BeadsDbLease` aggregate (`lib/foreman_server/aggregates/beads_db_lease.ex`)
serializes admission through Foreman only: a second `foreman run` for
the same DB returns `:queued` instead of dispatching. It does **not**
gate raw `br` or `bv --robot-plan` invocations launched from a shell
or unrelated automation while a lease is held. If you bypass Foreman
and write to the same Beads DB concurrently with a held lease, SQLite's
single-writer model still sees concurrent writers. Operators must
observe single-writer discipline themselves — the lease exists to
prevent two Foreman-dispatched runs from racing on the same DB, not
to mediate file-system access against unrelated processes. See
`test/foreman_server/workflow/br_bv_lease_concurrency_test.exs` for
the admission contract that *is* covered.

### Clean-vs-dirty cleanup

`cleanup: always` runs on every terminal phase. A clean worktree is
removed via `git worktree remove <path>` and `WorktreeCleaned` is
appended. A dirty worktree — local modifications, uncommitted
changes, or live workers still referencing it — is preserved on disk
and the projection stays unresolved. Operators see `reason: :dirty`,
`:active_workers`, `:clean_failed`, or `:resolve_dispatch_failed`
on `[:foreman_server, :vcs, :worktree, :orphan_preserved]`.
`Workflow.BootReconciliation` retries safe clean removal at every
startup; dirty worktrees are never auto-deleted. Operator
recovery is: `cd` into the worktree, inspect with
`git status` / `git diff`, preserve or discard local changes
(`git stash`, commit on the worktree branch, or
`git checkout -- <path>` / `git restore`), then remove with
plain `git worktree remove <path>` once the tree is clean.
Foreman never force-deletes; `Workflow.BootReconciliation`
retries unresolved safe cleanup at every startup.

### Concurrent PR caveat

Worktrees isolate files and indexes, and unique branches prevent
ref-name collisions, but two runs against overlapping code can still
produce semantically conflicting PRs. Each run produces a separate
PR; normal rebase/review policy resolves the conflict.

## 16. Cancelling a stuck run

Runs that have lost their worker, are wedged in a phase retry loop, or
are otherwise uninteresting can be terminated by an operator via the
`run.cancel` command. This is the only sanctioned way to mark a run
`terminal: true` with status `cancelled` — the worker protocol has no
equivalent on the operator surface.

### When the system leaves a run alone despite an old projection

Stuck detection reads each active run's `last_event_at_ms` against
an idle threshold (default 15 minutes). A run whose projection has
been quiet longer than that threshold is *not* automatically flagged
when there is live evidence that a phase is still in flight under a
known upper bound. The bound comes from the failure policy resolved
at dispatch: per-call opts, then the per-task-type override under
`:foreman_server, :agent_runtime, :failure_policies`, then
`default_timeout_ms` (default 60 s, raised in `config/dev.exs` to
30 min and to 60 min for `"implement-trd-beads"`). When that
resolved timeout has not yet elapsed, an execution that has not
reported a run-level event recently is treated as in-flight rather
than stuck. A wedged phase whose original executor was respawned —
so the supervisor's replacement has a different process identity
than the one that originally recorded the in-flight bound — is *not*
exempted by the stale entry: stuck detection takes over regardless,
so a dead predecessor cannot hide a wedged successor.

To distinguish a slow phase from a stuck one, read the run's
`last_event_at_ms` and the phase's resolved timeout: while the gap
is smaller than the policy's `timeout_ms`, the run sits in the
in-flight exemption window and will not be flagged; once the gap
exceeds the timeout, the run will be flagged on the next scan.

### CLI

```text
foreman run cancel --id <run-id> [--reason <reason>]
```

Flags:

- `--id` (required) — the run ID to cancel.
- `--reason` (optional) — human-readable reason stored in the
  `RunCancelled` event payload. Defaults to `operator_cancel`.

Example:

```text
foreman run cancel --id run-f971378012da4da2fec3ec74dbac325d --reason stuck_in_recovery
```

### HTTP

The same command is exposed via `POST /api/commands`:

```json
{
  "type": "run.cancel",
  "command_id": "op-cancel-1",
  "payload": {
    "run_id": "run-f971378012da4da2fec3ec74dbac325d",
    "reason": "stuck_in_recovery"
  }
}
```

### Validation

The envelope is validated at two layers before the Run aggregate
processes it:

1. `ForemanServerWeb.CommandController` accepts the request only if
   `run.cancel` is in the operator allowlist and the derived
   `aggregate_id` matches `"run:<run_id>"`.
2. `ForemanServer.CommandGateway` enforces a non-empty `payload.run_id`
   and rejects envelopes whose `aggregate_id` does not match the
   prefixed run ID.

On success the Run aggregate emits `RunCancelled` with the supplied
`reason` and marks the run `terminal: true` with status `cancelled`.
The projection is rebuilt from the event stream on the next read.

### When to use

- A worker's terminal event was lost and `RunLifecycleReconciler` has
  not yet observed the disconnect.
- A phase is stuck in retry and you want to stop retrying before the
  next dispatch.
- A run was started in error and should not have been.

## 17. Retrying a task bound to an orphaned run

Tasks whose bound run has already terminated (orphan remediation) are
recovered via the `task.retry` operator command. `task.retry` is the
only sanctioned way to clear a task's bound run id and put the task
back into `open` so a fresh dispatch can re-approve it.

### CLI

```text
foreman task retry --id <task-id> [--reason <text>]
```

Flags:

- `--id` (required) — the task ID to retry.
- `--reason` (optional) — human-readable reason recorded on the
  `TaskRetried` event payload. Omitted when not supplied.

Example:

```text
foreman task retry --id foreman-vcs-worktree-support --reason orphan_remediation_smoke
```

### HTTP

The same command is exposed via `POST /api/commands`:

```json
{
  "type": "task.retry",
  "command_id": "op-retry-1",
  "payload": {
    "task_id": "foreman-vcs-worktree-support",
    "reason": "orphan_remediation_smoke"
  }
}
```

### Terminal-attestation contract

`CommandGateway` reads the task projection, looks up the bound run
projection through `ProjectionStore.run/1`, requires the run to be
`terminal? == true` with a matching `task_id`, and attaches
`acknowledged_run_id`, `acknowledged_at`, and `run_terminal_reason`
to the payload as the single trusted boundary for terminal
attestation. The Task aggregate then enforces
`payload.acknowledged_run_id == state.run_id` before emitting
`TaskRetried`.

On success `TaskRetried` clears `run_id`, `approval_id`,
`approved_by`, `approved_at`, `workflow_snapshot`,
`acknowledged_run_id`, `run_terminal_reason`, and `run_terminal_at`,
and resets `status` to `open`. The projection is rebuilt from the
event stream on the next read.

### When the retry is rejected

The retry is rejected when:

- the task is not found (`task_not_found`),
- the task has no bound run (`missing_or_invalid` / `:run_id`),
- the run projection is missing (`run_not_found`),
- the run's `task_id` no longer matches the task
  (`run_task_binding_drift`),
- the run is not terminal (`run_not_terminal`; the gateway surfaces
  the current `status` so operators can diagnose
  stuck-but-not-yet-terminal runs).

### When to use

- Boot scan or `Dispatcher` fan-out observed a terminal run but the
  task is still `in_progress` against a dead run.
- A phase is stuck in retry and the run has gone terminal without
  emitting `task.run_terminated`.
- A worker session was lost and `RunLifecycleReconciler` has already
  marked the run terminal.

The Dispatcher subscriber path covers every terminal run event
(`RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
`RunBlocked`) — not just `run.cancel`. Each terminal event fans out
to the same `BootReconciliation.run_terminated/2` scan path that
the boot reconciliation runs at startup, so newly observed terminal
runs surface orphan tasks the same way boot scan does. The Dispatcher
also dispatches the matching per-DB Beads lease commands at terminal
time (`lease.release` for the holder, `lease.remove_waiter` for queued
waiters) so blocked runs cannot strand their DB lease. Operators use
`task.retry` directly for already-terminal orphans.