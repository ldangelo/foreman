# Operator reference — server, projects, task lifecycle, CLI, workflows

> Archived from the former monolithic `AGENTS.md` (2026-10-18), with accuracy corrections from the PR #561 review, to keep the always-loaded agent context small. Starting/stopping the server, task lifecycle, Go CLI surface, workflow install.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Operator Reference

### Auth postures (deliberately different per surface)

Which surfaces fail closed when `:api_bearer_token` (`FOREMAN_API_TOKEN`) is unset, and which do not. The asymmetry is intentional; do not "fix" it as part of unrelated cleanup.

|Surface|Plug / verifier|Token unset|
|---|---|---|
|`/api/*` (commands, projects, tasks, runs, queue, `/admin/workflows/*`)|`Plugs.BearerAuth`|`401` unless `:api, allow_insecure_local: true` (dev and test config set it; a release uses `FOREMAN_API_ALLOW_INSECURE_LOCAL=true`). A configured token is always enforced|
|`/api/jobsites`|`Plugs.RequireAuthenticated` (`:jobsite_api` pipeline)|`401`; also needs `:jobsites, allow_remote_start: true` to start anything|
|`/dashboard`, `/dashboard/runs`|`Plugs.RequireAuthenticated`|`401`|
|`/mcp` and stdio|`MCP.Auth`|refuses unless `:mcp, allow_insecure_local: true` (dev only; `false` in config/test)|
|`/webhooks/github`|HMAC (`VerifyGithubSignature`)|refuses every delivery|

Decision history: PRD-2026-0eac69b3 AC-018-2 originally kept `/api` open when no token was set ("the `/api` pipeline's existing permissive behaviour is unchanged, but MCP fails closed") and recorded in its risk 6 that enforcing a token breaks every caller that never set one. The project owner reversed that on 2026-10-19: `/api` now fails closed, mirroring `MCP.Auth`'s `allow_insecure_local` shape but under its own key (`config :foreman_server, :api, allow_insecure_local: <boolean>`, default `false`, exactly `true` required) because the MCP key is pinned `false` in the test env while the suite calls `/api` unauthenticated. The opt-in never weakens a configured token. Rollout consequence: any deployment that never set `FOREMAN_API_TOKEN` now answers `401` on `/api/*` (including `foreman init --force`'s `POST /api/admin/workflows/install`) until the token is set on the server and every client (the Go CLI sends `FOREMAN_API_TOKEN` when set) or the opt-in is enabled for a trusted local server. Still unauthenticated by design and unchanged: `/webhooks/external_trigger` and `/webhooks/operator/ingest` (keep them on a trusted network). Jobsite stays the stricter surface (no opt-in) because it runs agents on the server on behalf of a remote script.

### Starting the Phoenix Server

```bash
# From packages/foreman_server/
cd packages/foreman_server
mix phx.server
```

The server listens on `http://127.0.0.1:4766` (configured in `config/dev.exs`).
The Go CLI (`foreman`) defaults to `http://127.0.0.1:4766` — set `FOREMAN_API_URL` to override:

```bash
FOREMAN_API_URL=http://127.0.0.1:4766 foreman run list
```

### Operator run dashboard

Open `http://127.0.0.1:4766/dashboard/runs` with the configured browser bearer token (`Authorization: Bearer <token>` or `?token=<token>`) to inspect and control runs. `/dashboard` remains the Jido live dashboard. Run dashboard actions stay on the public command boundary: Stop=`run.pause` with `operator_pause`, Resume=`run.resume`, Reset=`run.reset`, Abandon=`run.remove`; Cancel, if shown, is distinct from Stop.

### Registering Beads-backed Projects

`foreman project create` / `foreman project update` require
`--task-provider-database-path <absolute-path>` when
`--task-provider=beads`; the CLI writes this as
`task_provider.config.database_path`.

### Stopping the Server

```bash
# Find the iex/mix process and kill it
ps aux | grep 'mix phx' | grep -v grep
kill <pid>
```

Or use `Ctrl+C` in the terminal running the server.

### Task Lifecycle

Tasks go through: `open` → `ready` → `in_progress` → `completed`/`failed`.

`project.reactivate` and `task.update` are also valid `POST /api/commands`
operator command types (`ForemanServer.CommandGateway.@allowed_operator_types`)
with no other narrative discussion in this file. `task.update` did have a Go
CLI verb (`foreman task update`, removed by TRD-018 below, same as
create/approve/retry/get/list); `project.reactivate` never had one. See
`docs/user-guide.md`'s HTTP API section for the complete allowlist.

**TRD-018 (2026-09-13) deleted `foreman task create`/`approve`/`retry`/`get`/
`list`/`update` entirely from the Go CLI** (the `task` dispatch case and its
handlers were removed from `packages/foreman_cli/cmd/foreman/task.go`, which
still exists for shared HTTP helpers used by other command files; invoking
any of the removed verbs now produces the CLI's standard "unknown
command" error, indistinguishable from a typo). `foreman run
list/get/cancel/pause/resume/remove/reset` are unaffected. This does NOT remove the underlying `task.create`
/ `task.approve` / `task.retry` domain command types dispatched through
`CommandGateway`/`CommandRouter` — those still exist and are the mechanism
BeadsWatcher's TRD-007 auto-approval (`dispatch_new_bead/2`) uses internally
the moment a bead labeled `foreman-exec` transitions to `status: open`. What changed is the
OPERATOR-FACING entry point: Beads (`br create`, or hand-editing a bead to
`status: open` with the `foreman-exec` label) is now the sole task creation interface, not a CLI verb. The
step-by-step CLI examples below predate that change and are kept, annotated,
because the aggregate-level prerequisites and guard behavior they describe
(dependency checks, idempotent-retry exemption, archived-project checks) are
unchanged and still apply to the internal command types — only the `foreman
task <verb>` invocation syntax no longer works.

#### 1. Create a task — REMOVED, see note above

`foreman task create` no longer exists. A task is now created by a bead
transitioning to `status: open` **and** carrying the `foreman-exec` label
(BeadsWatcher's label gate skips beads with no labels or without
`foreman-exec`, leaving them open with no task created); BeadsWatcher's status gate (TRD-004) and
workflow-selection wiring (TRD-005) dispatch the internal `task.create`
command automatically. The flag/behavior notes below describe that internal
command's semantics, not a CLI you can invoke:

**Flags:** `--project` and `--title` are required; `--id` is optional
(auto-generated via the task provider when omitted). `--workflow-type`
selects the workflow manifest (e.g. `implement-trd-beads`,
`implement-trd`, `plan`). `--trd-path` is a project-relative path to a
tracked git blob, required by the CLI when `--workflow-type` is
`implement-trd` or `implement-trd-beads`, and must be committed before
approval. The CLI has no `--priority` flag; set it via a raw
`POST /api/commands` `task.create` payload (`priority`, integer 0-4) if
needed — Beads validates it as a Beads priority for
`implement-trd-beads` tasks. The MCP `foreman_task_create` helper requires
`description` for `FOREMAN_TASK_DESCRIPTION`, passes `prompt` separately for
`:prompt`-action phases, and defaults `auto_approve: true`.

#### 2. Approve a task — REMOVED from the CLI, see TRD-018 note above

Approval transitions `open` → `ready` and triggers workflow dispatch. Was
invoked via `foreman task approve --id <task-id> --approved-by operator`;
that CLI verb is gone. The prerequisites below describe the internal
`task.approve` command's guard behavior, still exercised by BeadsWatcher's
auto-approval dispatch, not a CLI you can invoke directly:

**Prerequisites (verified against `aggregates/task.ex` and
`command_gateway.ex`):**

- The task must exist (`command_gateway.ex`'s `task.approve` clause of
  `validate_aggregate_id/1` looks it up via
  `ProjectionStore.task_projection/1`) and be `open`
  (`Task.require_approvable/1`, `task.ex:427`) — anything else,
  e.g. already `ready`/`in_progress`, is rejected as
  `:task_not_approvable`.
- The `trd_path` (if the task carries one) must be a committed git blob
  at `HEAD`.
- Every task id in the task's `dependencies` list must be a task whose
  status is `closed` (`CommandGateway.require_dependencies_satisfied/2`).
  Anything else is rejected as
  `{:task_dependencies_unsatisfied, [{id, reason}]}`, listing EVERY
  unsatisfied dependency in declaration order with its reason — a status
  string, `:not_found` for an id with no task, or `:malformed` for a
  non-binary id **or an empty string**. Note `failed` does NOT satisfy: it
  is terminal but did not produce the work the dependent task needs.

  An idempotent approval retry is exempt: when the task projection already
  records `approval_id == command_id`, the guard returns `:ok` without
  reading dependencies at all. The module docstring promises a re-sent
  command succeeds "even if the assets have since changed", and a
  dependency's status is such an asset — approve while it is `closed`, let
  `task.retry` return it to `open`, re-send the original command, and a
  guard that judged the retry would report a failure that never happened.
  The approval is already committed and the dispatch is deduplicated by
  `command_id` downstream, so there is no second event to prevent. The
  guard governs NEW approvals only.

  The `dependencies` value itself must be a list. `task.create` refuses a
  present non-list as `{:invalid_envelope, :invalid_dependencies}`; absence
  is still fine, since absent and malformed are different (§5.3). A
  malformed value already in the store from before that validation existed
  refuses the APPROVAL as `{:task_dependencies_malformed, value}` rather
  than raising in the read model: `ProjectionStore.init/1` rebuilds
  projections from the event log, so raising would turn one bad historical
  event into an application boot failure — the `WorkerStdout` failure in
  "Durable Run Logs" below, repeated.

  This mattered concretely. The read model first carried the field as
  `event.dependencies || []`, which is the shape §5.4b names explicitly:
  `false || []` yields `[]` exactly as `nil || []` does. A `task.create`
  carrying `dependencies: false` returned `{:ok, ...}`, stored `false` on
  the event, projected `[]`, and approved and dispatched with no dependency
  check at all — the same inertness this guard closes, re-entered through
  malformed input. Verified by probe before and after, not reasoned about.
  The projection now PRESERVES a non-list so the guard can refuse it;
  flattening bad data into a valid-looking default is what caused this.

  This check did not exist until it was added deliberately, and the way
  it was missing is instructive. `task.create` accepted `dependencies`
  (`task.ex:93`), `CommandGateway` defaulted it (the `task.create` clause
  of `enrich_operator_command/1`),
  the aggregate stored it (`task.ex:37,69`) and `TaskCreated` carried it
  (`task_created.ex:37`) — but `Task.require_dispatchable/1`
  (`task.ex:461-470`) reads only `status`, `run_id` and `approval_id`, and
  `ProjectionStore`'s `TaskCreated` handler dropped the field entirely. So
  the whole path existed except the read, and a task declaring
  dependencies dispatched immediately regardless of them. Do not treat the
  presence of a field on a command, an aggregate and an event as evidence
  that anything consumes it — the same lesson as `FOREMAN_ARTIFACT_PATH`
  and `foreman_queue_status`.

  It is a GUARD, not a dependency DAG: no ordering, no cycle detection,
  and no automatic dispatch when the last dependency closes. The operator
  re-approves. It lives in `CommandGateway` rather than the aggregate
  because it is inherently cross-aggregate — `Task` can see only its own
  state — and `ProjectionStore` is the read model built for that, which
  the `task.create` clause already uses for `project_projection/1`.
  Relatedly, `Task.apply_event/2` has a `TaskDependencyAdded` clause
  (`task.ex:150`) that NOTHING emits: only eight `task.*` commands are
  handled and none produces that event, so dependencies can be set at
  creation and never afterwards. Left in place rather than deleted, but do
  not read it as a working mutation path.
- Approval does **not** re-check the project's archived status —
  unlike `task.create` (`command_gateway.ex:236-239`,
  `task.ex:512-518`), no project-archived check runs on the
  `task.approve` path. No `task_provider` configuration is required
  either; that block only matters for provider-tracked (Beads-linked)
  tasks, and ad-hoc tasks approve without one.

#### 3. Monitor a task

`foreman task get <task-id>` is REMOVED (TRD-018). Use:

```bash
foreman run get <run-id>
foreman run list
```

Task statuses: `open` (created), `ready` (approved, waiting for dispatch), `in_progress` (running), `completed`, `failed`, `cancelled`.

#### 4. Cancel, pause, or resume a task/run

`foreman task retry` is REMOVED (TRD-018) — no CLI replacement exists for
retrying the internal `task.retry` command; it remains internal-only.

```bash
foreman run cancel --id <run-id> --reason "reason"
foreman run pause --id <run-id> --reason "reason"   # stop now; keep the run resumable
foreman run resume --id <run-id>                      # continue a paused run
foreman run remove --id <run-id>
foreman run reset --id <run-id>
foreman run approve-merge --id <run-id> --approver <name> --identity <github:login>
foreman run merge --id <run-id>                       # squash-merge the approved PR
```

**Unattended-run-control (2026-09).** `run cancel` no longer just marks the
run projection terminal: `Dispatcher.handle_run_terminated/3` now also
requests `RunControl` to kill the dispatched agent — including the
OS-level process, via `RunControl.cancel_agent/1` ->
`Jido.Harness.Run.cancel/1` — for `RunCancelled`, `RunFlaggedStuck`,
`RunFailed`, and `RunDeleted` (not `RunCompleted`/`RunBlocked`, where the
executor has already finished or is halting on its own). `run pause`
interrupts the current phase the same way but commits its partial work to
the run branch first and keeps the run's worktree, slot, and Beads lease
claim releasable-but-resumable rather than terminal. `run resume`
re-enters the run at the first non-`completed` phase, rehydrating the
persisted worktree rather than re-creating it, and re-runs that phase from
scratch against the committed partial state — a resumed phase whose agent
produces no *new* output will fail its `requiredFile` discovery gate
exactly as a first attempt would; that is correct, not a regression to
soften.

### Go CLI Commands

`task create`/`approve`/`retry`/`get`/`list`/`update` are REMOVED (TRD-018, 2026-09-13) —
the `task` dispatch case and its handler functions were deleted from
`packages/foreman_cli/cmd/foreman/task.go` (51 lines remain: shared HTTP
envelope/JSON helpers used by other command files, not task-verb handlers);
invoking any of them produces the CLI's standard "unknown command" error.
The remaining surface:

```bash
foreman run list             # List run projections
foreman run get <id>         # Fetch run projection
foreman run cancel --id <id> --reason <text>
foreman run pause --id <id> --reason <text>  # stop now, resumable
foreman run resume --id <id>                  # continue a paused run
foreman run remove --id <id> # Remove run and clean worktree/branch
foreman run reset --id <id>  # Clear failed/stuck run projection
foreman run approve-merge --id <id> --approver <name> --identity <github:login>  # open the merge gate
foreman run merge --id <id>  # squash-merge the approved PR (pinned to the approved head)
foreman project list         # List projects
foreman project get <id>     # Fetch project

# Workflow install (one-time bootstrap per machine)
foreman workflow install
```

**Installed copies are not compared with the bundled ones.** Dispatch never checks `~/.foreman/workflows/` against `priv/defaults/workflows/`: an old-format copy fails validation at load (`{:missing_phase_action, i}`), but an older, still-valid copy runs silently. After editing bundled workflows or prompts, run `foreman init --force` to refresh the installed copies.

### Workflows

Bundled workflows live in `packages/foreman_server/priv/defaults/workflows/`:

| Workflow | Select via | Description |
| --- | --- | --- |
| `assess` | `--workflow-type assess` | Analyze impact, constraints, and risks before implementation begins. |
| `discover` | `--workflow-type discover` | Scope the request and collect the repository context needed for execution. |
| `fix` | `--workflow-type fix` | Fix an issue via the ensemble fix workflow. |
| `implement` | `--workflow-type implement` | Generate and refine the code changes required for the task. |
| `implement-trd` | `--workflow-type implement-trd` | Implement a TRD using the ensemble skill. |
| `implement-trd-beads` | `--workflow-type implement-trd-beads` | Implement a TRD using Beads-backed ensemble skill with Kata/pi agent. |
| `plan` | `--workflow-type plan` | Run the plan workflow (create-prd → create-trd). |
| `prd` | `--workflow-type prd` | Full ensemble chain: create-prd, refine-prd, create-trd, refine-trd, implement-trd. |
| `release` | `--workflow-type release` | Finalize outputs, publish deliverables, and complete release steps. |
| `review` | `--workflow-type review` | Review the run's work with the CodeRabbit CLI and this repository's rules, then open the pull request. |
| `trd` | `--workflow-type trd` | Create a TRD from a PRD and implement it via the ensemble chain. |
| `verify` | `--workflow-type verify` | Run validation, testing, and quality checks for the completed work. |

---

