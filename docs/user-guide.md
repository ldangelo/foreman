# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and
command syntax, see the [CLI Reference](./cli-reference.md).

## Overview

Foreman orchestrates AI coding agents against a repository through
isolated git worktrees, with an event-sourced Elixir/Phoenix backend as
the single source of truth. It has two runtime pieces:

| Component | Technology | Role |
|-----------|------------|------|
| `foreman` CLI | Go | Thin HTTP client: posts commands to `/api/commands`, reads projections from `/api/*`. Holds no state of its own. |
| Foreman server (`foreman_server`) | Elixir/OTP + Phoenix | Owns everything: event store, CQRS aggregates, projections, the scheduler, worktree/VCS operations, agent dispatch, PR reconciliation, MCP server. |

There is no separate Node CLI or Node worker process. Agents run
**in-process** inside the Elixir server via `ForemanServer.AgentRuntime`
and the vendored `Jido.Harness` package (see
[Agent runtime and Jido Harness](#7-agent-runtime-and-jido-harness)
below).

**Event sourcing:** every state transition is a domain event appended to
`foreman_events`. Projections (task/run/project/queue read models) are
rebuilt from that log and are what `GET /api/*` endpoints and `foreman
project|task|run get|list` read.

### Task and run lifecycle, at a glance

```text
task.create ──▶ task.approve ──▶ (RunAdmission) ──▶ run dispatched
   open           ready                                in_progress
                                                            │
                                          TaskExecutionCompleted/Failed
                                                            │
                                                      closed | failed
```

A task can be tracker-backed (a Beads/TaskProvider issue drives its
approval and completion callbacks) or **ad-hoc** — a task carrying only a
free-text `prompt`, with no tracker issue at all. Both go through the
same `task.create` → `task.approve` path; see
[Ad-hoc task dispatch](#3-ad-hoc-task-dispatch-unified-with-the-task-path).

Once a run is admitted, its workflow's phases run in the order the
workflow YAML defines. Bundled workflow manifests live in
`packages/foreman_server/priv/defaults/workflows/*.yaml`:
`assess`, `discover`, `fix`, `implement`, `implement-trd`,
`implement-trd-beads`, `plan`, `prd`, `release`, `trd`, `verify`. A
workflow name is a server-side manifest selector, validated by
`Catalog.load/1` at dispatch time — there is no client-side allowlist.
The catalog root defaults to `~/.foreman/workflows` and is overridable
via `config :foreman_server, :workflow_root`.
PR creation is not phase-driven; see
[AutoPR](#pr-creation-and-merge-reconciliation) below.

Each run executes in **one** git worktree, isolating one agent's edits from your
main checkout and from every other concurrent run. Unless the workflow says
otherwise, the worktree is provisioned by the run's first phase at
`~/.foreman/worktrees/<project-id>/<task-id>/<run-id>/workspace` on branch
`foreman/<task-id>/<run-id>` — both path and branch include
`<task-id>/<run-id>` so retries stay unique and easy to navigate; a `worktree:` block may change the path
and branch or switch provisioning off entirely (see below). Every
phase reads an earlier phase's documents as ordinary files. Foreman commits
whatever each phase produced at the phase boundary, so the run branch
accumulates the whole pipeline and is what AutoPR proposes.

The worktree is configured by a **workflow-level** `worktree:` block, declared at
the top of the manifest beside `name:` and `phases:` — not on a phase. A run has
exactly one worktree, so a phase has nothing to decide about it:

```yaml
name: prd
worktree:
  enabled: true            # false opts the whole workflow out
  branch: foreman/{task_id}/{run_id} # {task_id} and {run_id} are placeholders
  path: workspace          # leaf dir under ~/.foreman/worktrees/<project>/<task>/<run>/
  cleanup: never           # never | always | on_success
phases:
  - name: create-prd
    command: "/skill:create-prd"
```

`cleanup` decides when the directory is reclaimed: `never` (the default) keeps
it, `always` reclaims on success and on failure, and `on_success` reclaims only
on success so a failed run's checkout survives for inspection. The default is
`never` because the worktree is the checkout AutoPR pushes from.
`foreman run remove --id <run-id>` reclaims it (and the local branch) whenever
you no longer need it.

`base` may pin the checkout to a specific ref. For `implement-trd` and
`implement-trd-beads` it must resolve to the ImplementationContext's frozen
`source_revision`, and Foreman fails the run if it does not; for every other
workflow the base is the project checkout's `HEAD` when the run's first phase
starts.

## Local Development Environment

`direnv allow` loads Devbox and sources `.env` on entering the
repository. The real script catalog (see `devbox.json`; do not trust an
older list you've seen elsewhere):

```bash
# ONE-TIME:
devbox run setup            # copy .env, install mix deps

# DAILY:
devbox run up                # bring up the Langfuse/otel stack
devbox run server            # start the Phoenix server (foreground)
devbox run iex                # start with iex for interactivity
devbox run ps                 # show service status
devbox run logs                # tail otel-collector logs
devbox run logs:stack          # tail litellm-langfuse stack logs

# DATABASE:
devbox run db:migrate
devbox run db:reset
devbox run db:console

# TESTING:
devbox run test               # all tests
devbox run test:unit          # everything except :langfuse-tagged
devbox run test:langfuse       # only the OTel+Langfuse e2e path

devbox run info                # command + status summary
devbox run env:list             # current env vars + endpoints
```

The dev Phoenix server listens on `http://127.0.0.1:4766`
(`packages/foreman_server/config/dev.exs`). The Go CLI also defaults to
`http://127.0.0.1:4766`; set `FOREMAN_API_URL` only when you need to
override that endpoint:

```bash
foreman project list
```

### Authentication

- Set `FOREMAN_API_TOKEN` (CLI) and the server's
  `:foreman_server, :api_bearer_token` config to require
  `Authorization: Bearer <token>` on every `/api/*` request.
- `/api/*` also accepts `?token=<token>` for narrow tooling.
- When the server has no token configured (the local dev default),
  authentication is bypassed entirely.

## Core Concepts

### Projects

A project is a repository registered with Foreman. Commands operate on
one project at a time via `--project-id`/`--project`.

### Create a project

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads \
  --task-provider-database-path /srv/foreman/project-123/.beads
```

### Get one project

```
foreman project get project-123
```

### Update a project

```
foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123
```

### Delete a project

```
foreman project delete project-123
```

### List projects

```
foreman project list
```

Use `foreman project list --include-archived --format json` when you need archived projects or raw JSON.

`project delete` soft-deletes (archives) a project and is **rejected**
while the project has active runs; pass `--force` to print the blocking
run IDs.

### Tasks

A task is the unit of dispatchable work. It carries a title, optional
description, a `task_type` (legacy classification field) and/or
`workflow_type` (the workflow manifest selector), and — for ad-hoc
work — a free-text `prompt`.

`foreman task create`/`approve`/`get`/`retry` are REMOVED (TRD-018,
2026-09-13) — invoking any of them now produces the CLI's standard
"unknown command" error. Task creation is driven by Beads instead of
an operator-invoked CLI verb:

```bash
br create --title "Fix flaky retry" --type fix
```

BeadsWatcher observes the bead (or its later transition to `status:
open`) and dispatches the internal `task.create` + `task.approve`
commands automatically — no separate approval step is needed. Use
`foreman run get <run-id>` / `foreman run list` (see "Runs" below) to
monitor the resulting run, and re-open the bead (`br update <id>
--status=open`) to retry once its bound run is terminal.

Select the workflow via the bead's type (mapped through a manifest's
`task_types:` declaration — see `foreman doctor`), not a CLI flag. Workflows
requiring `ImplementationContext` (`implement-trd`, `implement-trd-beads`)
read the TRD path from the bead's own `agent_context.trd_path` field, set on
the bead directly (`br update <id> --agent-context '{"trd_path":"docs/TRD/..."}'`)
— there is no `--trd-path` CLI flag any more, and no separate approval step:
BeadsWatcher creates and auto-approves the task in one action when the bead
transitions to `open`.

### Runs

A run is one dispatched execution of a task's workflow, in its own
worktree.

```bash
foreman run list --project-id foreman --status failed --limit 5
foreman run get <run-id>
foreman run cancel --id <run-id> --reason stuck_in_recovery
foreman run pause --id <run-id> --reason operator_pause
foreman run resume --id <run-id>
foreman run remove --id <run-id>
foreman run reset --id <run-id>
```

- `run cancel` marks the run terminal (`cancelled`) and kills the
  dispatched agent, including its OS-level process, via `RunControl`.
- `run pause` interrupts the current phase the same way, but first commits
  the phase's partial work to the run branch and leaves the run resumable
  (`paused`) rather than terminal — it releases the run's slot and Beads
  lease without reopening the underlying task.
- `run resume` continues a `paused` run: it re-acquires a slot/lease,
  rehydrates the persisted worktree, and re-runs the interrupted phase from
  its last committed state onward. A resumed phase that produces no *new*
  output fails its discovery gate exactly as a first attempt would.
- `run remove` terminates the run, releases its slot and any per-DB
  Beads lease, and best-effort cleans the worktree and local branch.
  Use it when a run is wedged and you want a clean slate.
- `run reset` clears a **failed or stuck** run's projection state so it
  can be resubmitted fresh; cancelled or completed runs are rejected
  with `{:run_not_resettable, "<status>"}`.

Phases have no default execution timeout: a workflow's `timeout_minutes:`
(alias `timeoutMinutes:`) is optional, and `0` or an absent key both mean
"run until it finishes" rather than falling back to a fixed ceiling.
Declare a positive `timeout_minutes:` on a phase to opt it back into a
deadline.

### Agent command assets

`foreman commands` generates agent-native Foreman shortcuts for Claude Code plus copyable generate-only assets for Pi/OMP, Codex, and OpenCode. The assets were thin shell wrappers over `foreman task create`, `foreman run submit`, `foreman run list`, `foreman run get`, and `foreman task get`; the `task create`/`task get` wrappers are REMOVED (TRD-018, 2026-09-13) along with the CLI verbs they wrapped, so those two generated shortcuts now fail with an "unknown command" error until the generator is updated. The `run submit`/`run list`/`run get` wrappers are unaffected. Generated files inherit `FOREMAN_API_URL` and `FOREMAN_API_TOKEN` instead of embedding secrets.

Common commands:

```bash
foreman commands inventory
foreman commands generate --agent all --output ./foreman-agent-commands
foreman commands install --agent claude --scope project
foreman commands validate
```

The `task create`/`task get` agent-command shortcuts above are removed
along with the CLI verbs they wrapped (TRD-018) — there is no longer a
generated task-creation shortcut, "later approval" step, or `--trd-path`
flag. Use `foreman run submit` or the generated `foreman-run-submit` asset
for one-step ad-hoc execution; drive `implement-trd`/`implement-trd-beads`
work through Beads as described above instead.

Support states:

| Agent | Native install | Behavior |
|---|---|---|
| Claude Code | Project-local verified | Writes Markdown slash-command files under `.claude/commands/foreman` by default; existing files require `--force`. |
| Pi/OMP | Generate-only by default | Prints/writes copyable Markdown and an unsupported-native-install reason because the native command path/format is not verified here. |
| Codex | Generate-only | Prints/writes copyable Markdown and marks native install unsupported until a stable native contract is verified. |
| OpenCode | Generate-only | Prints/writes copyable Markdown and marks native install unsupported until a stable native contract is verified. |

## 2. Operator API surface

All external domain mutations go through `POST /api/commands`. The
operator allowlist (`ForemanServerWeb.CommandController.@allowed_types`,
mirrored by `ForemanServer.CommandGateway.@allowed_operator_types`) is
exactly:

- `project.register`
- `project.update`
- `project.archive`
- `task.create`
- `task.approve`
- `task.retry`
- `run.cancel`
- `run.remove`
- `run.reset`

`CommandController` derives or verifies `aggregate_id` before calling
`CommandGateway`. The expected form is `<prefix>:<id>` (`task:<task_id>`,
`run:<run_id>`, `project:<project_id>`). A mismatched supplied
`aggregate_id` is rejected before the aggregate handles the command.

Response shapes:

- Success: `201` with `{"status": "accepted", "result": {...}}`.
- Refused command type: `403` with `{"error": "command_not_allowed", "type": "..."}`.
- Malformed envelope: `400` with `{"error": "invalid_envelope", "reason": "..."}`.
- Optimistic-concurrency conflict: `409` with `{"code": "version_conflict", "current_version": N}`.
- Project archive blocked by active runs: `409` with `{"code": "project_has_active_runs", "run_ids": [...]}`.
- Domain rejection: `422` with `{"error": "...", "detail": ...}` or `{"error": "..."}`.

Other ingress paths are separate:

- Workflow install/remove: `POST /api/admin/workflows/install` and
  `POST /api/admin/workflows/remove`.
- Webhooks: `/webhooks/external_trigger`, `/webhooks/github`,
  `/webhooks/operator/ingest`.
- MCP: `/mcp` (also stdio; see [MCP tool integration](#9-mcp-tool-integration)).
- Dev-only dashboards: `/debug/*` (dev env only) and `/dashboard/*`
  (bearer-token guarded, every env).

Read endpoints are projection-only:

- `GET /api/work/{id}` returns the (legacy, read-only) work projection
  for a historical `work.submit` request, or `{error: "work_not_found"}`
  with `404`. The `work.*` write ingress was retired in favor of the
  task path (below); this endpoint remains only so pre-existing work
  records stay inspectable.
- `GET /api/runs/{id}` returns `{run: ...}` with stringified keys, or
  `{error: "run_not_found", run_id: "..."}` with `404`. Every projected
  run carries `pr_url` — the URL of the PR the run opened, or `null`
  when Foreman recorded none. `GET /api/runs` carries the same field on
  each listed run.
- `GET /api/tasks/{id}`, `GET /api/projects`, `GET /api/projects/{id}`,
  and `GET /api/queue` expose corresponding projections.

## 3. Ad-hoc task dispatch (unified with the task path)

There is a single dispatch ingress: `task.create` (+ `task.approve`). A
task may carry a `prompt` and skip tracker/Beads issue creation entirely
by setting `provider_tracked: false`; setting `auto_approve: true` on
the same `task.create` call immediately approves and dispatches it, so a
caller gets one-call ad-hoc dispatch without a separate `task.approve`
round trip.

Example command envelope:

```json
{
  "type": "task.create",
  "command_id": "op-task-1",
  "aggregate_id": "task:adhoc-abc123",
  "payload": {
    "task_id": "adhoc-abc123",
    "project_id": "foreman",
    "task_type": "task",
    "workflow_type": "fix",
    "title": "Update docs/user-guide.md for issue #410",
    "prompt": "Update docs/user-guide.md for issue #410",
    "provider_tracked": false,
    "auto_approve": true
  }
}
```

Current behavior:

- `task_id` and `project_id` must be non-empty; `project_id` must refer
  to an existing, non-archived project.
- `prompt` is optional; when present it is written into
  `workflow_snapshot["input"]["prompt"]` at approval time and rendered
  into any `{{input.prompt}}` / `{{input.prompt_argument}}` command
  placeholders.
- `provider_tracked` defaults to `true` (matches every pre-existing
  tracker-backed task). Set it to `false` for ad-hoc dispatch: the task
  aggregate skips the synchronous Beads/tracker `create` call at
  `task.create` time, and `RunExecutor` skips claim/complete/fail
  callbacks during the run.
- `auto_approve` is consumed by the gateway only — it is never
  persisted on `TaskCreated`. On success, `CommandGateway` immediately
  dispatches the matching `task.approve` (deterministic `command_id`,
  so a retried `task.create` cannot mint a second approval) and returns
  *that* result to the caller, so the HTTP response carries
  `approval_id` and `run_id` alongside `task_id`.
- HTTP response is `201` with `{status: "accepted", result: ...}`. Treat
  this as acknowledgement; read `GET /api/tasks/{task_id}` and
  `GET /api/runs/{run_id}` for the stable projections.

## 4. CLI work and run commands

### `foreman run submit`

```text
foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]
```

`foreman run submit` posts a `task.create` envelope with
`provider_tracked: false` and `auto_approve: true` — this is the CLI's
ad-hoc dispatch verb, unified onto the task path described above.

- `--workflow` is required. Workflow names are validated server-side by
  `Catalog.load/1`; there is no client-side allowlist.
- `--prompt` is required.
- `--project-id` is required and must name an existing non-archived
  project.
- `--work-id` is optional and is an alias for the minted task ID; the
  CLI generates `adhoc-<hex>` when omitted (minted client-side so the
  server's no-id `task.create` flow, which resolves the ID through the
  task provider, is never triggered for an untracked task).
- `--backend` is optional. The CLI accepts `pi`, `claude`, `codex`, and
  `opencode`; it omits the field when the value is the default `pi`.
  This is a client-side readiness label only — see the caveat below.
- `--base-branch <branch>` is optional and captured at the protocol
  level only per
  [TRD-2026-80ba0665](TRD/TRD-2026-80ba0665-branch-parent-resolution.md).
  The default parent branch is the operator's checkout, not `"main"`:
  `RunExecutor` records `git symbolic-ref --short HEAD` of the project
  checkout when the run's first phase starts, and AutoPR opens the PR
  against that branch. A detached checkout resolves to no branch at
  all, which is a logged error and no PR rather than a fallback. Use
  `gh pr edit <n> --base <branch>` to retarget a PR that needs a
  different base.

Backend caveat: `--backend` is a client-side value only — the payload
key is dropped by `task.create` (the aggregate builds its `TaskCreated`
payload explicitly field-by-field and ignores unrecognized keys), so it
never reaches admission. Current Jido Harness execution supports `pi`
and `claude` providers only; `codex` and `opencode` remain stale
CLI-accepted values until (if ever) a provider adapter is added for
them.

For arbitrary server workflow manifests (e.g. `implement-trd`,
`implement-trd-beads`), `run submit` cannot help — those need a
`--trd-path`, which it does not accept. `foreman task create
--workflow-type ...` followed by `foreman task approve` used to be
the way to run them, but both verbs are REMOVED (TRD-018,
2026-09-13). Create a bead instead, with `--agent-context
'{"trd_path":"<project-relative-path>"}'` and a `--type` that maps to
the target workflow, then transition it to `status: open`;
BeadsWatcher reads `agent_context.trd_path` and dispatches the
internal `task.create` + `task.approve` pair automatically (a bead
missing a required `trd_path` is instead moved to `blocked` with an
explanatory comment).

### Task dependencies at approval

`foreman task approve` is REMOVED (TRD-018, 2026-09-13). The guard
behavior below still describes the internal `task.approve` command,
exercised automatically by BeadsWatcher's auto-approval — not a CLI
verb an operator can invoke directly.

A task may carry a `dependencies` list of other task ids. The internal `task.approve` command
refuses while any of them is not `closed`, reporting
`{:task_dependencies_unsatisfied, [{id, reason}]}` with **every** unsatisfied
dependency in declaration order — a status string, `:not_found` for an id with no
task, or `:malformed` for a non-string id or an empty string. `failed` does not
satisfy: the dependency is finished but did not produce the work the dependent
task needs.

An idempotent approval retry — re-sending the same `command_id` for an approval
that already committed — bypasses the check entirely, so a dependency that has
since been reopened cannot turn a succeeded approval into a reported failure.

The value must be a list. Since it is settable only through a raw JSON payload
(see below), `task.create` refuses a present non-list up front as
`{:invalid_envelope, :invalid_dependencies}` — omitting the field is still fine.
A malformed value stored before that validation existed refuses the approval as
`{:task_dependencies_malformed, value}` rather than being silently read as "no
dependencies".

This is a guard, not a scheduler. Nothing dispatches the task
automatically when its last dependency closes. `foreman task approve`
is REMOVED (TRD-018, 2026-09-13); BeadsWatcher dispatches
`task.approve` only once, at bead import (TRD-007), so there is
currently no operator-invocable path to retry approval after a
dependency later closes — the same category of gap as `task.retry`
below. There is also no ordering or cycle detection.

The Go CLI has no `--dependencies` flag, so the field is settable only through a
raw `POST /api/commands` `task.create` payload, the same as `priority`. And
dependencies can only be set at creation: no `task.*` command adds one to an
existing task.

Before this guard existed the list was accepted, stored, and written onto
`TaskCreated` while nothing read it, so a task with unmet dependencies
dispatched immediately.

### `foreman task retry` — REMOVED (TRD-018)

`foreman task retry --id <task-id> [--reason <text>]` no longer
exists: TRD-018 (2026-09-13) deleted it along with `task create`/
`approve`/`get`. Invoking it now produces the CLI's standard "unknown
command" error, and no CLI replacement exists for retrying the
internal `task.retry` command — it remains internal-only. The guard
behavior it exposed is unchanged:

Use `task.retry` only for a task whose bound run is already terminal.
`CommandGateway` reads the task projection, verifies the bound run
exists, checks `terminal? == true`, requires matching `task_id`, then
attaches trusted terminal attestation fields (`acknowledged_run_id`,
`acknowledged_at`, `run_terminal_reason`). The Task aggregate then
clears run-bound fields and returns the task to `open`.

The retry is rejected when the task is missing, has no bound run,
references a missing run projection, references a run bound to another
task, or the run is not terminal.

## 5. Task lifecycle

Task lifecycle is event-driven:

```text
open -> ready -> in_progress -> closed | failed
blocked -> ready -> in_progress -> closed | failed
```

Lifecycle details:

- `task.create` defaults status to `open`; the aggregate also
  recognizes `blocked` as a valid non-terminal task status.
- `task.approve` enriches the operator payload with trusted workflow
  data and moves an `open` or `blocked` task to `ready`.
- Dispatch requires `ready` plus bound `run_id`/`approval_id`; it emits
  `TaskDispatched`, moving the task to `in_progress`.
- Terminal execution emits `TaskExecutionCompleted` or
  `TaskExecutionFailed`. The task projection stores success as `closed`
  and failure as `failed`.
- `task.retry` is only for a task still bound to a terminal run, or
  already `failed` by the terminal invariant. Success clears run-bound
  fields and returns the task to `open`.

Run projections use a separate, wider status vocabulary: `completed`,
`failed`, `blocked`, `deleted`, `stuck`, or `cancelled`, depending on
the terminal event.

## 6. Worker runtime and Overwatch

`ForemanServer.Overwatch` is enabled by default outside tests. Command
phases run through this path:

```text
RunExecutor -> Overwatch.start_phase/2 -> LaunchWorker -> JidoHarnessWorker
```

Current behavior:

- `RunExecutor` materializes the phase prompt, chooses the Jido Harness
  provider from the request context, builds the execution cwd/env, and
  calls `Overwatch.start_phase/2`.
- `LaunchWorker` starts the adapter, registers the worker pid with
  `Overwatch.Tracker`, emits `WorkerStarted` with sequence `0`, then
  sends the activation handshake.
- A newly reserved run can be admitted as `awaiting_worker`;
  `WorkerStarted` is the signal that moves the run to `in_progress`.
- `JidoHarnessWorker` runs `Jido.Harness` in a supervised task after
  activation, emits periodic `WorkerHeartbeat`, emits `WorkerExited` on
  normal completion, forwards normalized `{:ok, text} | {:error,
  reason}` to `RunExecutor`, then exits normally so the supervisor can
  clean up.
- If the harness task crashes before returning a result, the worker
  emits best-effort `WorkerExited` and forwards `{:error,
  {:task_crashed, reason}}`.
- Worker relaunch is crash-only: a worker that finished the phase
  (`:normal`) or was torn down (`:shutdown`) ends the child, while a
  crashed worker is relaunched and counted by
  `Overwatch.CrashLoopDetector`.

## 7. Agent runtime and Jido Harness

The only bundled runtime adapter is the in-process
`ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`. There is no
shell-out CLI adapter and no separate worker process — agent execution
happens inside the Elixir server.

Default runtime config:

```elixir
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  agent_strategy: :react,
  agent_model: "auto"
```

The adapter routes through `ForemanServer.AgentRuntime.JidoHarness` and
the vendored `Jido.Harness` package. Supported upstream providers are
`:pi`, `:claude`, and `:litellm`.

Provider semantics:

- Requests default to `:pi` unless runtime context sets
  `provider: :claude` (or `:litellm`).
- `:litellm` requires a provider entry with `baseUrl` configured in
  `~/.pi/agent/models.json` (the pi coding agent reads this file for
  custom provider definitions). Configure your LiteLLM proxy there,
  e.g. providers.create then config then model_selection below.

- Requests default to `:pi` unless runtime context sets
  `provider: :claude`.
- Unknown providers return `:unsupported_provider`.
- A selected but unavailable provider returns `:backend_unavailable`
  without falling back to another provider.
- `JidoHarnessAdapter.available?/0` checks whether either bundled
  provider is installed.

## 7.2 Model and provider selection

Each workflow YAML phase can declare a model at `phases[].models.default`,
which flows through `RunExecutor → base_context → JidoHarness → pi CLI
--model` flag. The phase model overrides the provider's built-in default
model. Example:

```yaml
phases:
  - name: assess
    prompt: assess.md
    models:
      default: claude-3-5-sonnet
```
A phase may also declare `provider:` in its `context:` block to select
`:litellm` (routes through `~/.pi/agent/models.json` configured
`baseUrl`) or `:claude` instead of the default `:pi`.

Foreman does NOT route model selection based on the model name itself —
it passes the declared model string verbatim to the selected provider's
command line. The operator decides which provider ships which model
via `models.json` configuration.

## 7.3 pi provider configuration

The `:litellm` provider requires operator-side configuration in
`~/.pi/agent/models.json` (or `$PI_CODING_AGENT_DIR/models.json`):

```jsonc
{
  "providers": {
    "litellm": {
      "baseUrl": "http://localhost:4000",
      "api": "openai-completions"
    }
  }
}
```

Without this entry, `:litellm` is not in `models.json`, the `:litellm`
provider will fail quickly. See the pi coding agent docs for the full
models.json schema.

## 8. Telemetry, OTel, LiteLLM, and Langfuse

Local stack topology:

```text
Foreman OTLP exporter -> ops/otel-collector -> Langfuse v3
```

Defaults and env vars:

- Foreman OTel defaults to `http://localhost:4318` in `config/config.exs`.
- `devbox run up` starts `ops/otel-collector`, which listens on local
  `4318`/`4317` and joins the `litellm-langfuse-stack_default` Docker
  network.
- The collector forwards traces with `otlphttp/langfuse` to
  `http://langfuse-web:3000/api/public/otel`; the exporter appends
  `/v1/traces`.
- Langfuse v3 OTLP ingest requires HTTP Basic auth using
  `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`. Bearer auth with only the
  public key returns `403`.
- In production, set `OTEL_EXPORTER_OTLP_ENDPOINT` when
  `http://localhost:4318` is not the target collector/ingest URL.
- LiteLLM defaults to `LITELLM_ENDPOINT=http://localhost:4000`;
  `agent_model: "auto"` maps through `:jido_ai` model aliases to
  LiteLLM.

SigNoz operational logs are separate from the Langfuse LLM-trace path.
Foreman keeps Langfuse traces on `OTEL_EXPORTER_OTLP_ENDPOINT` and adds an
opt-in Phoenix Logger bridge for operational logs only:

- `FOREMAN_SIGNOZ_LOGS_ENABLED=true` enables the bridge.
- `FOREMAN_SIGNOZ_OTLP_ENDPOINT` points at the collector/SigNoz OTLP logs
  endpoint; default is `http://localhost:4318/v1/logs`.
- `FOREMAN_SIGNOZ_OTLP_HEADERS` accepts comma-separated `key=value` headers.
  Diagnostics report only endpoint host/port and never header values. Setting
  any header requires `FOREMAN_SIGNOZ_OTLP_ENDPOINT` to use `https://`; boot
  raises otherwise to avoid sending credentials over plaintext.
- `FOREMAN_SIGNOZ_LOG_LEVEL` defaults to `info` in production.
- Test config remains no-network: log export is disabled unless a test installs
  the capture exporter explicitly.
- `ops/otel-collector/signoz-logs.example.yaml` is a reference collector logs
  pipeline: OTLP receiver -> batch processor -> `otlphttp/signoz_logs`.

These four env vars are parsed once into `config :foreman_server, :signoz_logs`
in `packages/foreman_server/config/config.exs`.

Retention is enforced by SigNoz/storage, not Foreman. Use a 30-day default
retention policy for Foreman operational logs unless the deployment has a
stricter compliance requirement.

## 9. MCP tool integration

The server exposes an MCP endpoint at `/mcp` (HTTP, recommended) and via
`mix foreman.mcp.stdio` (stdio, for clients that spawn a child process).
Both transports share `ForemanServer.MCP.Dispatch`, so their tool sets
and behavior cannot diverge.

**Read tools** are always advertised: `foreman_doctor`,
`foreman_queue_status`, `foreman_project_list`, `foreman_project_get`,
`foreman_workflow_list`, `foreman_workflow_get`,
`foreman_workflow_validate`, `foreman_prompt_get`, `foreman_work_get`,
`foreman_run_get`, `foreman_run_status`, `foreman_run_get_logs`,
`foreman_run_get_events`, `foreman_run_get_activity`, `foreman_inbox_get`,
`foreman_task_list`, `foreman_task_get`.

- `foreman_run_status` returns a bounded status DTO from run and phase
  projections (`run_id`, `status`, `terminal`, `project_id`, `task_id`,
  `workflow_name`, `current_phase`, timestamps, and `failure_reason`).
- `foreman_run_get_logs` reads durable worker stdout/stderr events from
  `worker:<run_id>:<worker_id>` streams. Known runs with no output return
  an empty result; unknown runs return `NOT_FOUND`.
- `foreman_inbox_get` reads operator-facing run progress messages from the
  per-run inbox projection. Use it alongside logs/events/activity: inbox
  messages are agent-authored progress notes, logs are raw stdout/stderr,
  events are durable system facts, and activity is heartbeat/liveness data.

**Write tools** (`foreman_task_create`, `foreman_task_update`,
`foreman_task_add_comment`, `foreman_run_cancel`, `foreman_run_pause`,
`foreman_run_resume`, `foreman_inbox_send`, `foreman_workflow_put`,
`foreman_workflow_delete`, `foreman_prompt_put`) are unadvertised and refused unless
`allow_workflow_writes: true` is set in `:foreman_server, :mcp` config.

`foreman_inbox_send` appends concise progress to the run inbox via the public
`inbox.send` operator command. It requires `run_id` plus a 1-2,000 character
`body`, accepts optional caller-stable `message_id`/`command_id`, and only
allows JSON-safe metadata keys `phase_id`, `worker_id`, `session_id`, and
`severity`. Prompts tell agents to send phase start, material milestone,
blocker, and phase completion notes when the tool is available, never secrets,
prompts, large logs, or command output; denial/unavailability must not block
work. Built-in `prd`/`fix` command phases receive the same guidance through a
worker `system_prompt` sidecar, so their slash-command prompt text stays
unchanged.

`foreman_task_add_comment` appends a structured Work Log comment to the task
provider issue bound to a run. It requires `run_id`, `workflow_name`,
`phase_name`, and a 1-2,000 character `description`; Foreman resolves the task
and provider issue server-side, composes the comment body, and does not accept a
Beads id, provider issue id, or raw body from the caller. Bundled prompts tell
agents to use it at phase start, material milestones, blockers, and completion;
denial/unavailability must not block work.

After editing bundled prompts or workflows, run `npm run build` if assets
need regeneration and `foreman init --force` to install fresh runtime
copies.

Tool call failures are MCP tool errors carrying the gateway's
structured reason, never transport-level JSON-RPC errors.

- `foreman_task_list` lists all tasks, optionally filtered by
  `project_id` and canonical `status` (`open`, `ready`, `in_progress`,
  `blocked`, `closed`, `failed`). It supports `limit` (default 100, max
  500) and `offset` (default 0), and returns `{tasks, total, limit,
  offset, next_offset}`.
- `foreman_task_get` returns the full projection for one task.
- `foreman_task_update` updates mutable task fields (`title`,
  `description`, `priority`, `status`). Requires `task_id` and at
  least one field to update.
- `foreman_run_cancel` dispatches `run.cancel` with `run_id` and
  `reason`; the dispatched agent, including its OS-level process, is
  killed via `RunControl`.
- `foreman_run_pause` dispatches `run.pause` with `run_id` and `reason`,
  interrupting the current phase after committing its partial work and
  leaving the run resumable.
- `foreman_run_resume` dispatches `run.resume` with `run_id`, re-entering
  the run at its first non-completed phase.


## 10. Task-provider (Beads) enablement

A project links to a task tracker by setting a `task_provider` block in
its project config (`provider:` + `config:`, including `database_path` for
the Beads JSONL/db). `bv`/`br` remain the only writers of that store from
outside Foreman; see AGENTS.md's "Per-DB Beads lease" section for the
write-serialization guarantee Foreman itself provides once a run is admitted.

- **Atomic `task.create`.** For a project with a configured `:create`
  provider, `task.create` mints the Bead and emits `TaskCreated`
  together (`ForemanServer.Aggregate.Actor`'s four-stage pipeline); the
  Bead id comes back as `external_id`. `foreman task create` is
  REMOVED (TRD-018, 2026-09-13); recover the Bead id via `GET
  /api/tasks/:id` instead of CLI stdout output. A project without a
  `:create` provider takes the no-op path: no Bead, no `external_id`.
- **Inbound sync.** Set `config :foreman_server, :start_beads_watcher?,
  true` to run one `BeadsWatcher` per registered project, rescanning its
  JSONL from scratch on every fs event/poll (relying on the projection
  store for dedupe, not a byte-offset cursor) and dispatching
  `task.create` for Beads Foreman doesn't yet own.
- **Orphan janitor.** Set `config :foreman_server,
  :start_beads_orphan_janitor?, true` to run `BeadsOrphanJanitor`,
  which closes Beads whose matching Foreman task never landed or
  already terminated, after a grace window.
- **Health check.** `ForemanServer.CLI.DoctorTaskProvider.run/1`
  (dispatched via `ForemanServer.CLI.run(["doctor", "task_provider"])`)
  reports per-project provider health and the janitor's cached
  `orphan_backlog` counters. It is **not currently wired to the Go
  CLI** — there is no `doctor` case in
  `packages/foreman_cli/cmd/foreman/main.go`'s dispatch table, so
  `foreman doctor task_provider` does not run today despite being
  referenced elsewhere; invoke the Elixir module directly (e.g. from
  an `iex -S mix` session) until that wiring exists.
- **Remediation.** `foreman task retry` is REMOVED (TRD-018,
  2026-09-13); see §4 for what's unchanged internally and what isn't.
  Never mutate the provider issue by hand while Foreman still owns
  it.

## Day-to-day workflow

### 1. Start or check the server

```bash
devbox run server
```

If commands fail with a connection error, confirm `FOREMAN_API_URL`
points at the running server (`http://127.0.0.1:4766` in dev) and that
`devbox run ps` shows it up.

### 2. Register the project (once)

```bash
foreman project create --id my-project --path /path/to/repo --task-provider beads --task-provider-database-path /path/to/repo/.beads
```

### 3. Create and approve a task

`foreman task create` and `foreman task approve` are REMOVED
(TRD-018, 2026-09-13). Create a bead instead — BeadsWatcher dispatches
the internal `task.create` + `task.approve` pair automatically the
moment it transitions to `status: open`:

```bash
br create --title "Add cooldown retry for transient CLI failures" \
  --description "When a provider reports a transient rate limit, retry after cooldown instead of terminal failure." \
  --type fix
```

— or dispatch ad-hoc work in one call:

```bash
foreman run submit --project-id my-project --workflow fix \
  --prompt "Add cooldown retry for transient CLI failures"
```

### 4. Monitor

```bash
foreman run list --project-id my-project --status in_progress
foreman run get <run-id>
```

`foreman task get <task-id>` is REMOVED (TRD-018, 2026-09-13); read
the task projection directly via `GET /api/tasks/:id` (`curl` or an
MCP tool) instead.

Foreman has no TUI/cockpit today — monitoring is projection reads via
the CLI or `GET /api/*`. For live event/heartbeat detail during a run,
use the MCP tools `foreman_run_get_events` / `foreman_run_get_activity`,
or the `/debug/*` LiveView dashboards in a dev environment.

### 5. Recover a wedged or failed run

`foreman task retry` is REMOVED (TRD-018, 2026-09-13); re-opening the
bead (`br update <id> --status=open`) is the closest replacement once
the run below is terminal, though it goes through the same bead-import
path as creating a new task rather than a dedicated retry command.

```bash
foreman run get <run-id>                 # inspect status first
foreman run reset --id <run-id>          # failed/stuck only; clears projection for resubmission
foreman run remove --id <run-id>         # terminate + release slot/lease + best-effort cleanup
```

There is no interactive "kill-switch" or phase-resume primitive; a
stuck run is removed or reset, and the task is retried or recreated.

### PR creation and merge reconciliation

PR creation is **not** a workflow phase — bundled workflows declare no
`create-pr`/`pr-wait`/`merge` phases and there is no `checkpointPr`
option. `ForemanServer.Workflow.AutoPR.maybe_create_pr/1`, called from
`RunExecutor.finalize_run/1`, derives the PR from run state instead: it
checks `git rev-list --count base..head > 0` against the branch
recorded when the run's first phase started, publishes with `git push
-u origin <head>`, and calls `gh pr create`. The server separately
reconciles PR state in the background: if GitHub reports the PR merged
or closed, Foreman records that on the run and updates the associated
task. `POST /webhooks/github` accepts GitHub `pull_request` webhook
events (verified via `FOREMAN_GITHUB_WEBHOOK_SECRET`) as a real-time
optimization; polling remains the fallback.

By default one run yields at most one final PR. `auto_pr/1` is called from
`finalize_run/1`, after every phase has completed, and opens from the run's
single branch — `foreman/<task-id>/<run-id>` unless the workflow's `worktree.branch` says
otherwise. For task-backed runs, the final PR title is exactly the task title and
the final PR body is exactly the task description; if either is absent, blank, or
malformed, AutoPR returns a typed metadata error before publishing the branch.
Ad-hoc no-task runs keep the legacy generated run/artifact title and body.
Workflows may opt into phase boundary PR records with `stack_pr:
true` on an individual phase. Top-level `pr:`, `merge:`, `stacked:`, and
`checkpointPr` settings remain unsupported.
A `stack_pr: true` phase runs after that phase's normal commit decision and
before `PhaseCompleted`. It targets the recorded run base branch and uses the
same Foreman run branch as the head. Because every tagged phase shares that
head/base pair, GitHub usually exposes one open PR; later tagged phases push the
run branch again before reusing that PR URL, so the remote diff stays cumulative
from the run base instead of silently showing an older phase's head. If the head
has no commits beyond the run base, Foreman records a phase PR no-op and
continues. Push/create failures and closed matching PRs fail the responsible
phase with typed details. A created or reused phase PR record suppresses the
final AutoPR; no-op records do not.

**PR bodies carry unresolved review findings only when Foreman generates the body.**
Phase PRs, and final AutoPRs for ad-hoc no-task runs, append a `## Unresolved
review findings` section to the generated body when the PR-creating phase's
artifact contains a `<!-- FOREMAN_REVIEW_FINDINGS_START -->` /
`<!-- FOREMAN_REVIEW_FINDINGS_END -->` block — the format the bundled `review`
workflow's phases write. Task-backed final AutoPR bodies are exact task
descriptions and do not append artifact or review-finding sections. Absent or
empty blocks add nothing to generated bodies. An unterminated block (a start
marker with no matching end marker) is distinct: the phase found something and
failed to close its markers, so a warning is logged and the generated body
instead names the artifact for a human to check directly, rather than silently
dropping the findings.

**Commits are Foreman's, not the agent's.** At each phase boundary Foreman
stages and commits whatever the phase produced into the run's worktree, so an
agent that writes files without committing still leaves a proposable branch. The
message (`Foreman run <run-id> phase <n>`) and author are fixed, the commit skips
repository pre-commit hooks, and a phase that produced nothing creates no commit
— so AutoPR still proposes only real work.

A phase controls **whether** it commits, with a phase-level `commit:` boolean.
A phase can also request a phase PR record with `stack_pr: true`; that does not
force a commit. A phase can declare `timeout_minutes:` (camelCase `timeoutMinutes:` also accepted) as a
non-negative-integer number of minutes for its execution timeout; `0`, or an
omitted key, both mean no timeout, which is the default — Foreman only
falls back to the Elixir app-config failure policy / `default_timeout_ms`
when one is explicitly configured for that phase name.
Unlike `worktree:`, which is workflow-level because a run has only one worktree,
each phase produces its own output, so these are genuinely per-phase questions:

```yaml
phases:
  - name: create-prd
    command: "/skill:ensemble-full-create-prd --foreman"
    timeout_minutes: 10   # execution timeout in minutes (optional)
    commit: true          # commit this phase's work when it completes (default)
    stack_pr: true        # create/reuse a phase PR after the commit
  - name: refine-prd
    command: "/skill:ensemble-full-refine-prd --foreman"
    commit: false         # defer: a later phase's commit absorbs it
    stack_pr: true        # records no-op unless prior committed diff is ahead
  - name: create-trd
    command: "/skill:ensemble-full-create-trd --foreman"
    commit: true          # commits refine-prd's work together with its own
```

Omitting `commit:` means `true`, so the seven bundled workflows that declare
nothing keep committing every phase. Use `commit: false` to batch consecutive
phases into one reviewable commit.

One combination is **rejected when the workflow loads**, not at run time,
because nothing at run time can rescue it:

- A phase declaring `commit: false` that no later phase commits, in a workflow
  whose `worktree.cleanup` is `always` or `on_success`. The deferred changes
  live only in the run's worktree, and both of those modes delete it — so the
  work is destroyed with no branch and nothing for PR creation to propose. The
  error names the deferring phase and the cleanup mode, and states both fixes:
  commit the work in a later phase, or declare `cleanup: never`.

The same never-committed deferral is **accepted** under `cleanup: never` (the
default when you declare no `worktree:` block). There the work survives in the
worktree on disk, so a workflow that stages changes for you to inspect or commit
by hand is a legitimate thing to author. Because PR creation counts commits
only, such a run succeeds and produces no PR — so Foreman logs a warning when
the run reaches terminal, naming the deferring phase, and that warning also
fires when a run fails before reaching the phase that would have absorbed the
work.

Two earlier rules described here no longer exist. A `commit: false` phase
immediately before a `requiredFile:` phase was refused, on the theory that
document discovery would attribute the earlier phase's uncommitted document to
the gated phase; that refusal made deferral and discovery mutually exclusive and
so forbade exactly the batching the tag exists to provide, which is the shape the
`plan` and `prd` workflows want. Never-committed deferral was also refused
unconditionally, which is the rule now narrowed to the cleanup case above.

## Documentation Discipline

See `AGENTS.md`'s "Documentation Discipline" section for the mandatory
pre-completion gate: enumerate externally-visible identifiers a change
adds/removes/renames, grep them across `CLAUDE.md`, `AGENTS.md`,
`README.md`, this file, and `docs/cli-reference.md`, and fix or
explicitly annotate any stale hit. `docs/PRD/*` and `docs/TRD/*` are
point-in-time design specs, not living docs — leave their historical
claims as written; add a forward-pointer note instead of rewriting them.

## Safety Rules

- Keep the controller workspace clean before rerunning important tasks.
- Prefer targeted `run reset`/`task retry` over bulk retries.
- Inspect run/task projections and events before changing state.
- Do not manually mutate an active run's worktree unless you intend to
  take ownership of that run.

## Further Reading

- Command syntax: [CLI Reference](./cli-reference.md)
- Adding a Jido Harness provider: [docs/guides/adding-a-jido-harness-provider.md](./guides/adding-a-jido-harness-provider.md)

## Phase stall detection

Workflow authors can opt a phase into stall detection with `stall_detection`. `agent` detects no qualifying agent output; `messaging` detects no appended inbox/message progress. Example:

```yaml
phases:
  - name: wait-for-reply
    command: "/skill:verify"
    stall_detection:
      kind: messaging
      threshold_ms: 1800000
      policy: attention
```

Defaults: agent no-output = 900000 ms; messaging no-progress = 1800000 ms. Disable detector scheduling with `config :foreman_server, :stall_detection_enabled, false`. Do not use `0` or negative thresholds; validation treats those as malformed. A detected stall writes `RunStallReported`, updates `latest_stall` on run/phase/task projections, and appears in `foreman run get --format json`, MCP `foreman_run_status`, and API projection reads. Heartbeats alone are not progress.

## Outbound messaging delivery

Enable outbound Telegram/Slack delivery with `config :foreman_server, :messaging`. Runtime config keys: `enabled`, `provider`, `event_classes`, `dedupe_window_ms`, `run_update_rate_limit_ms`, `telegram: [token:, chat_id:]`, and `slack: [webhook_url:]`. `ForemanServer.Messaging.notify/2` never calls provider HTTP directly; it persists notification lifecycle state. The supervised dispatcher starts after `CommandRouter`, performs restart catch-up from the event log, subscribes to projection events, redelivers notifications with no durable terminal outcome (an in-flight attempt or a retryable failure is retried; only a recorded success or a non-retryable failure is skipped), guarantees at most one delivery per notification within one dispatcher process lifetime even if both catch-up and a live projection event observe it, and records redacted success/failure state. A catch-up or subscribe failure crashes the dispatcher under supervision rather than silently dropping live/replay delivery. Delivery failure is notification state only; it must not turn a healthy run into failed.
