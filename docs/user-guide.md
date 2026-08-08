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

Runtime ownership is split deliberately:

- `RunExecutor` drives `claim/3`, `complete/3`, and `fail/3`.
- `Workflow.BootReconciliation` drives orphan-reopen on boot.
- `set_priority/3` and `add_dependency/3` exist at the adapter
  boundary, but this slice does not introduce an operator CLI surface
  for them.

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
    command: "/skill:ensemble-full-create-prd --draft"
    requiredFile: planning.prd_path
  - name: create-trd
    command: "/skill:ensemble-full-create-trd --draft"
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