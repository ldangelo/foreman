# Foreman operator & developer guide

This guide is the operator source of truth for the current Elixir/Jido
runtime. It describes behavior audited from:

- `packages/foreman_server/lib/foreman_server/`
- `packages/foreman_server/lib/foreman_server_web/`
- `packages/foreman_cli/`
- `ops/otel-collector/`
- `devbox.json`

Speculative future behavior is intentionally omitted. For invariant developer
conventions, see [`../CLAUDE.md`](../CLAUDE.md).

## 1. Local development quickstart

Run commands from the repository root through `devbox`; it is the single entry
point for the local stack.

```bash
devbox run setup          # first-time .env + mix deps bootstrap
devbox run up             # litellm/langfuse stack + Foreman OTel collector
devbox run server         # Phoenix server on http://127.0.0.1:4766
devbox run iex            # same server with IEx
devbox run ps             # stack + collector status
devbox run logs           # Foreman OTel collector logs
devbox run logs:stack     # litellm/langfuse stack logs
devbox run info           # command catalog + endpoint summary
devbox run env:list       # relevant env vars + service URLs
devbox run test           # full ExUnit suite
devbox run test:unit      # ExUnit excluding :langfuse tests
devbox run test:langfuse  # only :langfuse-tagged OTel/Langfuse tests
devbox run test:all       # ExUnit with :langfuse tests included
devbox run db:migrate     # run Ecto migrations
devbox run db:rollback    # roll back one migration step
devbox run db:reset       # drop/recreate/migrate dev DB
devbox run db:console     # psql on the dev database
devbox run deps           # fetch mix deps
devbox run fmt            # format Elixir code
devbox run compile        # compile foreman_server
devbox run down           # stop services, keep volumes
devbox run reset          # destructive volume reset; prompts first
```

`devbox` shell initialization does all of this:

- sets `SHELL` when missing, needed by `erlexec` and similar deps;
- prefers cached Elixir `1.18.4` when available to avoid the known
  `telemetry_metrics` compile crash in `1.18.1`;
- defaults `LITELLM_LANGFUSE_STACK` to
  `$HOME/Development/Sunstone/litellm-langfuse-stack`;
- sources repo `.env`, then `$LITELLM_LANGFUSE_STACK/.env` when present;
- exports `FOREMAN_API_URL=http://127.0.0.1:4766` unless already set.

Outside devbox, set `FOREMAN_API_URL` yourself. The Go CLI compiled fallback
is still `http://127.0.0.1:4000`.

Auth:

- If the server has `FOREMAN_API_TOKEN`, send
  `Authorization: Bearer <token>` or set the same token in CLI env.
- `/api/*` also accepts `?token=<token>` for narrow tooling.
- When no token is configured, dev auth is bypassed.

## 2. Operator API surface

All external domain mutations go through `POST /api/commands`. The current
operator allowlist is:

- `project.register`
- `project.update`
- `project.archive`
- `task.create`
- `task.approve`
- `task.retry`
- `run.cancel`
- `work.submit`
- `work.cancel`

`ForemanServerWeb.CommandController` derives or verifies `aggregate_id` before
calling `ForemanServer.CommandGateway`. The expected form is `<prefix>:<id>`
(`task:<task_id>`, `run:<run_id>`, `work:<work_id>`, `project:<project_id>`).
A mismatched supplied `aggregate_id` is rejected before the aggregate handles
the command.

Other ingress paths are separate:

- workflow install/remove: `POST /api/admin/workflows/install` and
  `POST /api/admin/workflows/remove`
- webhooks: `/webhooks/*`
- MCP: `/mcp`
- dev-only dashboards: `/debug/*` and `/dashboard/*`

Read endpoints are projection-only:

- `GET /api/work/{id}` returns the work projection directly, or
  `{error: "work_not_found"}` with `404`.
- `GET /api/runs/{id}` returns `{run: ...}` with stringified keys, or
  `{error: "run_not_found", run_id: "..."}` with `404`.
- `GET /api/tasks/{id}`, `GET /api/projects`, `GET /api/projects/{id}`, and
  `GET /api/queue` expose corresponding projections.

## 3. Work submission API

Example command envelope:

```json
{
  "type": "work.submit",
  "command_id": "op-work-1",
  "aggregate_id": "work:work-123",
  "payload": {
    "work_id": "work-123",
    "project_id": "foreman",
    "workflow": "fix",
    "prompt": "Update docs/user-guide.md for issue #410"
  }
}
```

Current behavior:

- `work_id` and `project_id` must be non-empty.
- `project_id` must refer to an existing, non-archived project.
- `workflow` and `prompt` must be non-empty strings.
- `CommandGateway` rejects client-supplied reserved fields:
  `submission_id`, `run_id`, and `workflow_snapshot`.
- `ForemanServer.Work.Submission.prepare/1` loads `<workflow>.yaml`, derives
  `submission_id` and deterministic `run_id`, and freezes the workflow snapshot.
- HTTP response is `201` with `{status: "accepted", result: ...}`. Treat this
  as acknowledgement only; read `GET /api/work/{work_id}` for the stable work
  projection and derived IDs.

The work projection stores `submitted`, `succeeded`, `failed`, or `cancelled`.
Queue position is currently `nil`; live run admission state is visible through
run projections and `GET /api/queue`, not the work read model.

## 4. CLI work and run commands

### `foreman run submit`

```text
foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]
```

Current CLI contract:

- `--workflow` is required and must be one of `prd`, `trd`, or `fix`.
- `--prompt` is required.
- `--project-id` is required and must name an existing non-archived project.
- `--work-id` is optional; the CLI generates `work-<random>` when omitted.
- `--backend` is optional. The CLI accepts `pi`, `claude`, `codex`, and
  `opencode`; it omits the field when the value is the default `pi`.

Important backend caveat: `--backend` is read-model metadata for `work.submit`,
not a runtime execution switch. `Work.Submission` builds the workflow snapshot
without `backend`, and `Work.RunPayload.from_work_projection/1` does not pass a
backend into admission. Current Jido Harness execution supports `pi` and
`claude` providers only; `codex` and `opencode` remain stale CLI-accepted values
unless a future provider is added.

Use `foreman run submit` for the curated work-request workflows (`prd`, `trd`,
`fix`). For arbitrary server workflow manifests such as `implement-trd` or
`implement-trd-beads`, create and approve a task with `--workflow-type`.

Example:

```text
foreman run submit --workflow fix --prompt "Update docs/user-guide.md for issue #410" --project-id foreman
```

### `foreman run get <run-id>`

Fetches `GET /api/runs/{id}` and prints the JSON response.

```text
foreman run get run-f971378012da4da2fec3ec74dbac325d
```

### `foreman run cancel --id <run-id> [--reason <reason>]`

Issues `POST /api/commands` with a `run.cancel` envelope. The gateway enforces
`aggregate_id == "run:<run_id>"`; the Run aggregate emits `RunCancelled`, making
the run terminal with status `cancelled`.

`--reason` defaults to `operator_cancel`.

```text
foreman run cancel --id run-f971378012da4da2fec3ec74dbac325d --reason stuck_in_recovery
```

### `foreman task retry --id <task-id> [--reason <text>]`

Use `task.retry` only for a task whose bound run is already terminal.
`CommandGateway` reads the task projection, verifies the bound run exists,
checks `terminal? == true`, requires matching `task_id`, then attaches trusted
terminal attestation fields (`acknowledged_run_id`, `acknowledged_at`,
`run_terminal_reason`). The Task aggregate then clears run-bound fields and
returns the task to `open`.

The retry is rejected when the task is missing, has no bound run, references a
missing run projection, references a run bound to another task, or the run is
not terminal.

## 5. Task lifecycle

Task lifecycle is event-driven:

```text
open -> ready -> in_progress -> closed | failed
blocked -> ready -> in_progress -> closed | failed
```

Operator shorthand sometimes describes the terminal branch as
`completed/failed`; the exact task read-model success status is `closed`.
Run projections use `completed`, `failed`, `blocked`, `deleted`, `stuck`, or
`cancelled` depending on the terminal event.

Lifecycle details:

- `task.create` defaults status to `open`; the aggregate also recognizes
  `blocked` as a valid non-terminal task status.
- `task.approve` enriches the operator payload with trusted workflow data and
  moves an `open` or `blocked` task to `ready`.
- Dispatch requires `ready` plus bound `run_id`/`approval_id`; it emits
  `TaskDispatched`, moving the task to `in_progress`.
- Terminal execution emits `TaskExecutionCompleted` or `TaskExecutionFailed`.
  The task projection stores success as `closed` and failure as `failed`.
- `task.retry` is only for a task still bound to a terminal run, or already
  `failed` by the terminal invariant. Success clears run-bound fields and
  returns the task to `open`.

## 6. Worker runtime and Overwatch

`ForemanServer.Overwatch` is enabled by default outside tests. Command phases
run through this path:

```text
RunExecutor -> Overwatch.start_phase/2 -> LaunchWorker -> JidoHarnessWorker
```

Current behavior:

- `RunExecutor` materializes the phase prompt, chooses the Jido Harness provider
  from the request context, builds the execution cwd/env, and calls
  `Overwatch.start_phase/2`.
- `LaunchWorker` starts the adapter, registers the worker pid with
  `Overwatch.Tracker`, emits `WorkerStarted` with sequence `0`, then sends the
  activation handshake.
- A newly reserved run can be admitted as `awaiting_worker`; `WorkerStarted` is
  the signal that moves the run to `in_progress`.
- `JidoHarnessWorker` runs `Jido.Harness` in a supervised task after activation,
  emits periodic `WorkerHeartbeat`, emits `WorkerExited` on normal completion,
  forwards normalized `{:ok, text} | {:error, reason}` to `RunExecutor`, then
  exits normally so the supervisor can clean up.
- If the harness task crashes before returning a result, the worker emits
  best-effort `WorkerExited` and forwards `{:error, {:task_crashed, reason}}`.
- Separate crash paths can emit `WorkerCrashed`; normal Jido metadata is not the
  operator result.

## 7. Agent runtime and Jido Harness

The only bundled runtime adapter is the in-process
`ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`. The old shell-out
`PiAdapter` is no longer shipped.

Default runtime config:

```elixir
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  agent_strategy: :react,
  agent_model: "auto"
```

The adapter routes through `ForemanServer.AgentRuntime.JidoHarness` and the
vendored `Jido.Harness` package. Supported upstream providers are `:pi` and
`:claude`.

Provider semantics:

- Requests default to `:pi` unless runtime context sets `provider: :claude`.
- Unknown providers return `:unsupported_provider`.
- A selected but unavailable provider returns `:backend_unavailable` without
  falling back to another provider.
- `JidoHarnessAdapter.available?/0` checks whether either bundled provider is
  installed. Automatic routing excludes unavailable adapters before invocation;
  policy routing can still select a primary candidate and then skip it during
  invocation if unavailable.
- Test config deliberately sets `adapters: []`; adapter tests opt in explicitly.

When adding a provider, update code and docs together. Do not document `codex`,
`opencode`, or `PiAdapter` as runnable backends until the runtime actually
supports them.

## 8. Telemetry, OTel, LiteLLM, and Langfuse

Local stack topology:

```text
Foreman OTLP exporter -> ops/otel-collector -> Langfuse v3
```

Defaults and env vars:

- Foreman OTel defaults to `http://localhost:4318` in `config/config.exs`.
- `devbox run up` starts `ops/otel-collector`, which listens on local
  `4318`/`4317` and joins the `litellm-langfuse-stack_default` Docker network.
- The collector forwards traces with `otlphttp/langfuse` to
  `http://langfuse-web:3000/api/public/otel`; the exporter appends
  `/v1/traces`.
- Langfuse v3 OTLP ingest requires HTTP Basic auth using
  `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`. Bearer auth with only the public
  key returns `403`.
- The collector computes `LANGFUSE_BASIC_AUTH` in `ops/otel-collector/entrypoint.sh`.
- In production, set `OTEL_EXPORTER_OTLP_ENDPOINT` when `http://localhost:4318`
  is not the target collector/ingest URL. `prod.exs` builds the same Basic auth
  header for both `:jido_otel` and `:opentelemetry_exporter` when both Langfuse
  keys are present.
- LiteLLM defaults to `LITELLM_ENDPOINT=http://localhost:4000`; `agent_model:
  "auto"` maps through `:jido_ai` model aliases to LiteLLM.

Useful checks:

```bash
devbox run env:list
devbox run ps
devbox run logs
```

## 9. Aggregate state model

Current aggregates use per-aggregate `State` structs, for example:

- `ForemanServer.Aggregates.Task.State`
- `ForemanServer.Aggregates.Worker.State`
- `ForemanServer.Aggregates.BeadsDbLease.State`

The shared `ForemanServer.Aggregate` module is a behavior/helper boundary, not a
legacy global `Aggregate.State` shape. New aggregate code and runbooks must not
depend on a generic top-level state map.

Rules for aggregate code:

- `initial_state/0` returns the aggregate's `%State{}` struct.
- `apply_event/2` uses explicit field updates such as `%State{state | field: value}`.
- Maps are fine for genuinely dynamic nested fields (`phase_status`,
  `worker_status`, config maps, retry history), not for fixed aggregate state.
- Struct construction does not replace domain invariant checks in
  `handle_command/2`.

## 10. Beads-backed workflow rules

For `implement-trd-beads`, Foreman derives immutable implementation context at
approval time:

- `trd_path`: normalized project-relative TRD path
- `trd_path_argument`: JSON-quoted shell argument
- `project_root`: absolute project root
- `source_revision`: exact `HEAD` SHA
- `implementation_key`: SHA256 of project + normalized TRD path
- `beads_database_path`: absolute Beads DB path from TaskProvider registry

These fields are server-derived. Operator payloads and phase YAML context cannot
override them.

Per-DB Beads lease:

- Foreman serializes Beads-backed run admission with the
  `beads_db_lease:<db_path>` aggregate.
- The key is the configured absolute DB path passed at acquire time.
- Path aliases and symlinks are not normalized; use one canonical absolute path.
- If the DB is free, `lease.acquire` makes the run the holder.
- If held by another run, `lease.acquire` enqueues a waiter and admission returns
  queued without starting the run supervisor.
- Releasing a holder with waiters emits `BeadsDbLeaseTransferred`, which promotes
  the head waiter in one event.
- Terminal run handling dispatches `lease.release` for holders and
  `lease.remove_waiter` for queued waiters.

Scope limitation: the lease protects only Foreman-dispatched runs. Raw `br`
writers and `bv --robot-plan` processes launched outside Foreman are not gated;
operators must still observe SQLite single-writer discipline themselves.

## 11. Workflow templates and prompts

Bundled workflow manifests and prompts live under
`packages/foreman_server/priv/defaults/workflows/` and related prompt defaults.
The runtime catalog loads manifests/prompts into memory and hot-reloads changed
files from the configured workflow root.

If you edit a source workflow or prompt, run:

```bash
foreman init --force
```

before dispatching a run that depends on it. Runtime dispatch fails fast when
installed prompts/workflows are stale.

## 12. Implementing TRD workflows

Use task approval, not `foreman run submit`, for implementation workflows:

```bash
foreman task create \
  --project foreman \
  --title "Implement TRD" \
  --workflow-type implement-trd \
  --trd-path docs/TRD/example.md

foreman task approve --id <task-id> --approved-by operator
```

For Beads-backed implementation, use `--workflow-type implement-trd-beads` and a
project with a Beads TaskProvider configuration. The TRD path must be a tracked,
committed git blob at `HEAD` before approval.

Workflow selection precedence at approval time is:

```text
workflow_type || task_type || default_task_type
```

`workflow_type` is independent from `task_type`; it selects the workflow
manifest. `task_type` remains the domain/category field.

## 13. Worktree cleanup expectations

`cleanup: always` runs on terminal phases. Clean worktrees are removed through
`git worktree remove <path>` and `WorktreeCleaned` is appended.

Dirty worktrees are preserved. Reasons include:

- `:dirty`
- `:active_workers`
- `:clean_failed`
- `:resolve_dispatch_failed`

Operator recovery:

```bash
cd <worktree>
git status
git diff
# preserve or discard changes, then:
git worktree remove <path>
```

Foreman never force-deletes dirty worktrees. `Workflow.BootReconciliation`
retries safe cleanup at startup.

## 14. Stuck and cancelled runs

Use `run.cancel` for operator-initiated cancellation. It is the sanctioned way
to mark a run terminal with status `cancelled`.

Stuck detection compares an active run's `last_event_at_ms` against the idle
threshold. A quiet run is not automatically flagged while there is evidence a
phase is still in flight under its resolved timeout. The timeout comes from
per-call opts, per-task failure policy, then `:default_timeout_ms`; dev config
raises common implementation timeouts for long-running agent work.

To distinguish slow from stuck, compare the run's `last_event_at_ms` with the
phase timeout. Once the gap exceeds the resolved timeout, stuck detection can
flag the run on the next scan.

## 15. Project and task-provider operations

Project commands use the same `POST /api/commands` envelope and are exposed by
CLI helpers. All mutations route through Phoenix -> `CommandGateway` ->
`CommandRouter`; the Go CLI never writes directly to the event store,
projection store, or Elixir state.

TaskProvider production wiring currently uses Beads (`br`). Useful operator
checks:

```bash
foreman doctor task_provider --project <project-id>
br ready --json
br show <id> --json
br sync --flush-only
```

After Beads mutations, run `br sync --flush-only` so exported JSONL is current.
