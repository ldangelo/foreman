# CLI reference

This slice ships `foreman`, a thin Go CLI around the Elixir/Phoenix
HTTP boundary. The CLI is **not** an alternate write path to the
event store. The commands documented here either query read models,
run diagnostics, or invoke admin asset materialisation on the server
host.

## Environment

| Variable | Default | Description |
|---|---|---|
| `FOREMAN_API_URL` | `http://127.0.0.1:4000` | Base URL of the Phoenix API. |
| `FOREMAN_API_TOKEN` | _unset_ | Optional Bearer credential. When unset the server bypasses auth (dev only). |

The CLI exposes no global flags; command-specific flags are listed
below. Run `foreman <command> -h` for per-command usage.

## Commands

### `foreman project create`

Register a project by POSTing `project.register` to `/api/commands`.

| Flag | Description |
|---|---|
| `--id ID` | **Required.** Project identifier. |
| `--path PATH` | **Required.** Absolute project path recorded in the projection. |
| `--task-provider PROVIDER` | **Required.** Task-provider adapter id, for example `beads`. |
| `--idempotency-key KEY` | Optional caller-supplied dedupe key; otherwise the CLI derives one from `path` and `task_provider`. |
| `--format json` | Print the accepted command response as JSON instead of the human summary line. |

Example:

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads
```

### `foreman project get <id>`

Fetch a single project projection with `GET /api/projects/:id`.

| Flag | Description |
|---|---|
| `--format json` | Print the raw JSON response instead of the human-readable summary. |

Example:

```
foreman project get project-123
```

### `foreman project update <id>`

Update a project's task-provider block by POSTing `project.update` to
`/api/commands`.

| Flag | Description |
|---|---|
| `--task-provider PROVIDER` | **Required.** Replacement task-provider adapter id. |
| `--idempotency-key KEY` | Optional caller-supplied dedupe key; otherwise the CLI derives one from `project_id` and `task_provider`. |
| `--format json` | Print the accepted command response as JSON instead of the human summary line. |

Example:

```
foreman project update --task-provider beads project-123
```

### `foreman project delete <id>`

Archive a project by POSTing `project.archive` to `/api/commands`.
This is a soft-delete: the project remains in the read model with
`archived: true`. The server rejects the archive while active runs
remain.

| Flag | Description |
|---|---|
| `--force` | On a `project_has_active_runs` conflict, print the blocking run ids to stderr before exiting with code `3`. |
| `--idempotency-key KEY` | Optional caller-supplied dedupe key; otherwise the CLI derives one from `project_id`. |

Example:

```
foreman project delete --force project-123
```

### `foreman project list`

List project projections with `GET /api/projects`. The default table
columns are `ID`, `PATH`, `ARCHIVED`, `REGISTERED`, and `VERSION`.

| Flag | Description |
|---|---|
| `--include-archived` | Include archived projects in the response (`include_archived=true`). |
| `--format json` | Print the project array as JSON. |
| `--format ndjson` | Print one JSON object per line. |

When the server enforces the current hard cap (1000 rows), the CLI
prints a truncation warning and operators can inspect `X-Total-Count`
for the full matching count.

Example:

```
foreman project list --include-archived
```


### `foreman run get <id>`

Fetch a run projection. Issues `GET /api/runs/:id`.

### `foreman run cancel --id <run-id> [--reason <reason>]`

Operator-initiated cancellation. Issues `POST /api/commands` with a
`run.cancel` envelope. The server validates the envelope, the
`CommandGateway` enforces `aggregate_id == "run:<run_id>"`, and the Run
aggregate emits `RunCancelled` (terminal, status `cancelled`).

Flags:

- `--id` (required) — the run ID to cancel.
- `--reason` (optional) — human-readable reason stored in the
  `RunCancelled` event payload. Defaults to `operator_cancel`.

Example:

```text
foreman run cancel --id run-f971378012da4da2fec3ec74dbac325d --reason stuck_in_recovery
```

### `foreman doctor task_provider`

Run the task-provider health check. The command emits one JSON object
per project that carries a `task_provider` block and exits non-zero if
any reported project is unhealthy.

Per-project fields include:

- `project_id`
- `provider_id`
- `contract_version`
- `br_version`
- `capabilities`
- `sample_ready`
- `schema_validation_failures`
- `janitor_enabled` — whether the `:start_beads_orphan_janitor?`
  flag is set for the running server (read from
  `Application.get_env/3`, not from supervisor liveness).
- `janitor_running` — whether `BeadsOrphanJanitorSupervisor` is
  currently registered and a janitor child exists for this project
  (boolean). `false` when the supervisor process is not running or
  no child is registered for `project_id`.
- `orphan_backlog` — snapshot of the janitor's last scan counters,
  `nil` when no scan has completed yet. When present it is a map
  with keys `lines_processed`, `lines_tagged`, `lines_untagged`,
  `lines_malformed`, `lines_retained`, `lines_closed`,
  `lines_age_young`, `lines_no_linked_at`. This is a CQRS read of
  the cached snapshot maintained by the janitor's own scan loop —
  the doctor MUST NOT call `BeadsOrphanJanitor.run_scan/2` itself.

Unhealthy reports surface only the allowlisted error fields:
`code`, `message`, `hint`, `exit_code`, `stderr_byte_count`, and
`redacted_fields`. Raw `stderr` is never printed.

### `foreman workflow install`

The CLI resolves the flag values to absolute paths via
`filepath.Abs` and POSTs them to the server in a JSON body. The
server's `WorkflowInstallController` forwards them to
`ForemanServer.WorkflowTemplate.Installer`, which performs all
file I/O via `File.cp/2` and `File.write/2`. The CLI never writes
to disk itself — `--target` and `--source` must therefore be paths
**on the server host**, not on the operator's local machine.

The catalog observes the install only when `--target` is the
catalog's configured root (hardcoded to `~/.foreman/workflows` by
`AssetCatalog.default/0`); installs to other paths are written to
disk but never picked up by the catalog. A successful install is
visible to consumers on the next catalog poll tick (default 2 s)
or immediately after `ForemanServer.Workflow.Catalog.reload/0`.

| Flag | Description |
|---|---|
| `--target PATH` | **Required.** Absolute path on the **server** (resolved via `filepath.Abs` in the CLI; `File.cp/2`/`File.write/2` in `WorkflowTemplate.Installer`). Must equal the catalog's configured root (`~/.foreman/workflows` by default) for the catalog to observe the install. |
| `--source PATH` | Absolute path on the server of the source `*.yaml` and `prompts/*.md` directory. |
| `--remote URL` | Remote URL of a workflow bundle. |
| `--retries N` | Retry attempts for remote installs (default `3`). |
| `--retry-delay-ms MS` | Delay between retries (default `250`). |

At least one of `--source` or `--remote` is required; both may be
set in the same invocation. The installer uses `File.cp/2` and
`File.write/2`; if the target already contains a same-named file,
it will be overwritten. Place custom templates under their own
filenames.

Example:

```
foreman workflow install \
  --target ~/.foreman/workflows \
  --source ./bundled-templates
```

The auto-install performed by `Workflow.Catalog.init/1` at boot is
a **no-op** when this command (or any other process) has already
materialised at least one `*.yaml` manifest under the target — see
`docs/user-guide.md` §7 for the exact condition.

### `foreman task create --task-type plan`

Create a task that flows through the `plan` workflow. The Go CLI
posts the standard `task.create` command to `/api/commands` with
`task_type: "plan"`. `--id`, `--project`, and `--title` are required;
`--task-type` selects the workflow discriminator. The CLI always
pretty-prints the raw command response (HTTP 201 with
`status: "accepted"`); there is no `--format` flag.

```
foreman task create \
  --id task-plan-1 \
  --project proj-abc \
  --title "Plan feature workflow" \
  --task-type plan
```

For Beads-backed projects (those whose `task_provider` capabilities
advertise `:create`), the Actor's synchronous hook
(`Aggregate.Actor.resolve_enriched_event_spec/3`) calls
`provider.create/2` **before** the event append, caches the
returned bead id against the command id in
`state.in_flight_beads`, then re-runs
`aggregate.handle_command/2` with the bead id populated as
`payload.external_id` so the persisted `TaskCreated` event records
the bead linkage. The CLI does not surface the bead id inline — the
command response itself only confirms acceptance. To retrieve the
bead id, run `foreman task get <task-id>` (which hits
`GET /api/tasks/:id`); the returned task projection includes
`external_id` for Beads-backed projects and `external_id: null` for
projects without a `:create` capability. Downstream tooling
correlates the Foreman task with its Beads bead by reading that
field, not from the create response. The actor's compensation path
(called when a stage-2 cache hit loses the append-conflict retry or
when a post-reload re-decision rejects) closes the cached bead via
`BeadsAdapter.complete/3` with a canonical `transition_comment`, so
on those characterized failure paths the Beads row is closed before
the error returns to the caller. Other append-failure modes outside
the conflict-retry path are not characterized here.

Once approved, the run executes two phases:

1. `create-prd` — invokes `/skill:ensemble-full-create-prd --foreman`
   and writes the draft PRD to `planning.prd_path` in the project's
   registered path.
2. `create-trd` — invokes `/skill:ensemble-full-create-trd --foreman`
   and writes the draft TRD to `planning.trd_path` in the same root.

Each phase receives a `planning.*` context block (see
`docs/user-guide.md` §14) covering the document year, correlation id,
slug, and the absolute paths Ensemble must use.

The required-file gate fires `:required_file_missing` if the
resolved path does not exist on disk when the phase starts. Operators
can inspect the failure via `foreman run get <run_id>` — the phase
projection records `failure_reason` containing the dotted key and
resolved path.

### `foreman task create --workflow-type implement-trd`

Create a task that flows through the `implement-trd` workflow. The
Go CLI posts the standard `task.create` command to `/api/commands`
with `workflow_type: "implement-trd"`. `--id`, `--project`,
`--title`, and `--trd-path` are required; `--workflow-type`
selects the implementation workflow discriminator. The CLI
pretty-prints the raw command response (HTTP 201 with
`status: "accepted"`); there is no `--format` flag.

```
foreman task create \
  --id task-impl-1 \
  --project proj-abc \
  --title "Implement auth TRD" \
  --workflow-type implement-trd \
  --trd-path docs/TRD/TRD-2026-auth.md
```

Once approved, the run executes a single phase that owns its own
worktree:

1. `implement-trd` — invokes
   `/skill:ensemble-full-implement-trd --foreman <trd_path_argument>`
   inside a Foreman-managed worktree pinned to the project's frozen
   source revision. See `docs/user-guide.md` §15 for the worktree
   contract and the env vars auto-injected at execution time.

The required-file gate fires `:required_file_missing` if the
resolved `trd-path` does not exist on disk when the phase starts.
Operators can inspect the failure via `foreman run get <run_id>`.

### `foreman task create --workflow-type implement-trd-beads`

Create a task that flows through the `implement-trd-beads` workflow
(Beads-backed two-task flow: scaffold a Beads hierarchy from the TRD
and then execute it). The CLI accepts the same flags as
`--workflow-type implement-trd`; the server resolves the Beads
database path and TRD scope from the project's planning context and
auto-injects them as `BEADS_DB` and `TRD_SCOPE` env vars at phase
execution time.

```
foreman task create \
  --id task-impl-beads-1 \
  --project proj-abc \
  --title "Implement auth TRD via Beads" \
  --workflow-type implement-trd-beads \
  --trd-path docs/TRD/TRD-2026-auth.md
```

> **Worktree lifecycle has no direct CLI.** The CLI does not expose
> `foreman worktree …`. Foreman creates, pins, and cleans the
> worktree on its own; there is no operator subcommand to invoke,
> inspect, or override that lifecycle. See `docs/user-guide.md` §15
> for the worktree contract and the server-side
> `ForemanServer.ProjectionStore.worktree_for_phase/3` /
> `worktrees_for_run/1` accessors for read-side consumption.

### `foreman task get <task-id>`

Fetch the task projection by hitting `GET /api/tasks/:id`. The CLI
pretty-prints the returned JSON. On success the projection carries:

| Field | Meaning |
|---|---|
| `task_id` | The Foreman task id (matches the `:id` flag used to create it). |
| `external_id` | The Beads issue id linked to this task, when the project's `task_provider` capabilities advertised `:create` at creation time. `null` when no provider was registered or the project has no `:create` capability. |
| `status` | Lifecycle status (`open`, `approved`, `retrying`, …). |
| `project_id` | Owning project. |

Operators correlate the Foreman task with its Beads bead by reading
`external_id` from this command's output — not from the
`foreman task create` response, which only confirms acceptance.

### `foreman task retry --id <task-id> [--reason <text>]`

Operator remediation path for tasks bound to orphaned runs. Issues
`POST /api/commands` with a `task.retry` envelope. The
`CommandGateway` reads the task projection, looks up the bound run
projection through `ProjectionStore.run/1`, requires the run to be
`terminal? == true` with a matching `task_id`, and attaches
`acknowledged_run_id`, `acknowledged_at`, and `run_terminal_reason`
to the payload as the single trusted boundary for terminal
attestation. The Task aggregate then enforces
`payload.acknowledged_run_id == state.run_id` and emits
`TaskRetried`, which clears `run_id`, `approval_id`, `approved_by`,
`approved_at`, `workflow_snapshot`, `acknowledged_run_id`,
`run_terminal_reason`, and `run_terminal_at`, and resets `status`
to `open`.

| Flag | Description |
|---|---|
| `--id ID` | **Required.** Task identifier. |
| `--reason TEXT` | Optional reason recorded on `TaskRetried`. |

The retry is rejected when:

- the task is not found (`task_not_found`),
- the task has no bound run (`missing_or_invalid` / `:run_id`),
- the run projection is missing (`run_not_found`),
- the run's `task_id` no longer matches the task
  (`run_task_binding_drift`),
- the run is not terminal (`run_not_terminal`; the gateway surfaces
  the current `status` so operators can diagnose
  stuck-but-not-yet-terminal runs).

The Dispatcher subscriber path (`run.cancel` →
`task.run_terminated`) remains in place for newly observed terminal
events; both paths converge on the same payload shape. Operators use
`task.retry` directly for already-terminal orphans.

Example:

```
foreman task retry \
  --id foreman-vcs-worktree-support \
  --reason orphan_remediation_smoke
```