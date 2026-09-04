# Foreman

Foreman orchestrates AI-agent workflows backed by the Elixir/Phoenix
service in `packages/foreman_server`. This repository contains:

| Path | Role |
|---|---|
| `packages/foreman_server/` | The Elixir/Phoenix runtime. Hosts the `ForemanServer.AgentRuntime` subsystem (TRD-2026-6af02293, TRD-2026-4212be7e) and the workflow catalog (TRD-2026-96872fc5). |
| `packages/foreman_cli/` | The Go CLI. Wraps the Phoenix HTTP boundary for operator use; the only operator-facing path into the runtime. |
| `packages/jido_harness/` | Vendored Sunstone-Partners fork of `agentjido/jido_harness`. The current agent-execution backend (see `JIDO_FORKS.md` for pinned SHAs). |
| `docs/PRD/` | Product requirements documents, one per design slice. |
| `docs/TRD/` | Technical requirements documents, one per design slice. |
| `docs/architecture/`, `docs/standards/`, `docs/guides/` | Architectural context, the project constitution, and step-by-step operator/developer guides. |
| `JIDO_FORKS.md` | Pinned Jido fork manifest — single source of truth for which SHA each Jido dependency references in `packages/foreman_server/mix.exs`. |
| `AGENTS.md` | Agent-context contract for coding subagents (read-only here). |
| `CLAUDE.md` | Durable developer architecture conventions (start here when modifying the runtime). |

## Subsystem documentation

| Slice | Doc |
|---|---|
| `foreman_server` agent runtime (TRD-2026-6af02293) | [`CLAUDE.md`](./CLAUDE.md) §1–§10 (developer conventions), [`docs/user-guide.md`](./docs/user-guide.md) (operator config & adapter extension). |
| Jido migration (TRD-2026-4212be7e) | `JIDO_FORKS.md` (fork inventory), `docs/guides/adding-a-jido-harness-provider.md` (provider extension), and per-PR notes in `docs/TRD/`. |
| Go/Elixir CQRS parity (TRD-2026-96872fc5) | per-PR notes in `docs/TRD/`; the `Workflow.Catalog` GenServer (CLAUDE.md §11) owns every manifest and prompt at runtime, hot-reloads on a 2 s poll, and auto-installs bundled templates when `~/.foreman/workflows` has no `*.yaml`. |

## Beads sync (atomic task.create + bidirectional sync)

The Go/Elixir CQRS slice wires Beads (the `br` CLI) into Foreman so
that projects with a configured `:create` task provider get
atomic `task.create` (mint Bead + emit `TaskCreated` together) and,
with the watcher enabled, inbound Beads appear as Foreman tasks.

- **Atomic `task.create` (provider-backed projects).** For projects
  with a configured `:create` provider, `POST /api/commands` with
  `task.create` runs the four-stage actor pipeline; the MCP
`foreman_task_create` helper requires `description` for `FOREMAN_TASK_DESCRIPTION`,
passes `prompt` separately for `:prompt`-action phases, and defaults
`auto_approve: true`. The aggregate
  emits a stage-1 `TaskCreated` event spec, the actor calls
  `provider.create/2` to mint a Bead, the actor re-decides with the
  Bead ID as `payload.external_id`, and `CommandRouter` appends the
  committed event. The Bead ID is surfaced in the HTTP response, so
  `foreman task create` prints the linked Bead ID on stdout. Projects
  without a `:create` provider take the no-op path: no Bead is
  minted, no `external_id` is surfaced, and the `task.create`
  response carries only the Foreman `task_id`.
- **Beads provider config.** Register Beads-backed projects with an
  absolute `task_provider.config.database_path`; the Go CLI requires
  `--task-provider-database-path` when `--task-provider=beads`.
- **Beads → Foreman (inbound).** Opt in with
  `config :foreman_server, :start_beads_watcher?, true`. The
  `BeadsWatcherSupervisor` spawns one `BeadsWatcher` per registered
  project; each watcher tails the project's JSONL and dispatches
  `task.create` for new Beads that Foreman doesn't yet own.
- **Orphan janitor.** Opt in with
  `config :foreman_server, :start_beads_orphan_janitor?, true`. After a
  grace window, `BeadsOrphanJanitor` closes Beads whose matching
  Foreman task never landed (stranded issuance) or whose Foreman task
  already terminated. The janitor caches its last scan counters as
  `orphan_backlog` (8 fields: `lines_processed`, `lines_tagged`,
  `lines_untagged`, `lines_malformed`, `lines_retained`,
  `lines_closed`, `lines_age_young`, `lines_no_linked_at`).
  `ForemanServer.CLI.DoctorTaskProvider` reads this snapshot via the
  supervisor's CQRS read boundary — it never triggers a scan itself,
  and `orphan_backlog` is `nil` until the first scan completes for a
  registered project. See §10 in `docs/user-guide.md` for how to
  invoke it today.
- **Operator remediation.** `foreman task retry` is the remediation
  path for tasks whose bound run is already terminal (see
  `docs/user-guide.md` §4).

Enablement, the per-project `task_provider` block, the doctor health
check, and the orphan janitor's opt-in semantics are documented in
[`docs/user-guide.md`](./docs/user-guide.md) §10. Note: the doctor
check (`ForemanServer.CLI.DoctorTaskProvider`) is not yet wired to the
Go CLI — `foreman doctor task_provider` does not run today; see §10
for the current invocation path. See
[`docs/cli-reference.md`](./docs/cli-reference.md) for the CLI surface
and [`CLAUDE.md`](./CLAUDE.md) §11–§13 for the architectural
invariants.

## Per-DB Beads lease (Beads write serialization)

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

- `lease.acquire` is atomic — if the DB is free, the run becomes the
  holder; if held, the run is enqueued as a waiter and admission
  returns `:queued`.
- `lease.release` and `lease.remove_waiter` are dispatched at every
  terminal run event (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`,
  `RunCompleted`, `RunFailed`, `RunBlocked`).
- When the holder releases with waiters, the aggregate emits a single
  `BeadsDbLeaseTransferred` event that releases the old holder and
  promotes the head waiter atomically.
- `RunAdmission.start/3` fail-closed: any uncertainty around the lease
  decision returns `{:error, ...}` and skips dispatch; a `:queued`
  decision returns without starting the supervisor and the dispatcher
  picks the run up again on `BeadsDbLeaseTransferred`.
- **Scope limitation — operator responsibility outside Foreman.** The
  lease serializes only admission through Foreman. External `br`
  writers and `bv --robot-plan` invocations launched outside Foreman
  (e.g. from a human shell or an unrelated automation) are NOT gated
  by this lease — if you bypass Foreman and write to the same Beads DB
  concurrently with a held lease, SQLite's single-writer model will
  still see concurrent writers. Operators must observe single-writer
  discipline themselves; this lease exists to prevent two
  Foreman-dispatched runs from racing on the same DB, not to mediate
  file-system access against unrelated processes.

See [`CLAUDE.md`](./CLAUDE.md) §15 for the architectural invariants.

## Task-provider boundary overview

The Go/Elixir CQRS task-provider slice keeps task-tracker ownership on
the Beads side and splits Foreman's responsibilities by lifecycle:

- `RunExecutor` drives claim, complete, and fail transitions during an
  active run.
- `Workflow.BootReconciliation` drives orphan-reopen on boot.
- `ForemanServer.CLI.DoctorTaskProvider` is the health check; it is not
  yet exposed as a Go CLI subcommand (see §10 below for how to invoke
  it today).

Enablement, the per-project `task_provider` block, and doctor output are
documented in [`docs/user-guide.md`](./docs/user-guide.md) §10.

Workflow phases support `commit:` to defer phase commits, `stack_pr:` to
request a phase PR record from the single Foreman run branch to the recorded run
base branch, and `timeout_minutes:` (alias `timeoutMinutes:`) to declare a positive-integer execution
timeout in minutes. Omitted phase timeouts fall back to the Elixir app-config
failure policy. The default run branch is `foreman/<task-id>/<run-id>` — `<task-id>` is
the provider-facing identifier when available (falls back to `<run-id>` for ad-hoc),
so each retry of the same task gets a unique branch. `stack_pr:` reuses the existing head/base PR when present, records
no-op when there are no committed diffs, and suppresses final AutoPR only for
created/reused phase PR records. Full operator semantics live in
[`docs/user-guide.md`](./docs/user-guide.md#pr-creation-and-merge-reconciliation).

## Agent runtime (Jido-harness backed)

The agent runtime is an OTP-supervised, backend-agnostic façade over
pluggable adapters. Callers register a module that implements
`ForemanServer.AgentRuntime.BackendAdapter`, then call
`ForemanServer.AgentRuntime.execute/3` to run prompts.

The current default adapter is
`ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter` (TRD-2026-4212be7e
JHA-T002 / JCR-T001), which delegates to the vendored
`Jido.Harness` package under `packages/jido_harness/`. Adapters for
`:pi`, `:claude`, and `:litellm` ship through Jido Harness; readiness
is checked at every `execute/3` call, and workflow phase `models.default`
values are forwarded to the selected provider as the run model (see
`CLAUDE.md` §1–§9).

```elixir
defmodule MyApp.ClaudeAdapter do
  use ForemanServer.AgentRuntime.BackendAdapter

  def name, do: :claude
  def capabilities do
    %{
      type: :remote,
      strengths: [:long_context, :code_review],
      weaknesses: [:image_input],
      supported_contexts: [:code_review, :brainstorm],
      cost_per_call: 0.012,
      typical_latency_ms: 4_500
    }
  end

  def available?, do: true

  def execute(%{prompt: prompt, context: ctx}, _opts) do
    MyApp.ClaudeAPI.complete(prompt, ctx)
  end
end

# Register via config (preferred)
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter]

# Call it:
ForemanServer.AgentRuntime.execute("Summarize this PR", %{pr: 123},
  strategy: :automatic, task_type: :code_review)
```

See [`docs/guides/adding-a-jido-harness-provider.md`](./docs/guides/adding-a-jido-harness-provider.md)
for the operator-facing provider extension flow, and
[`docs/user-guide.md`](./docs/user-guide.md) §7 for the agent runtime
and adapter overview.

## Agent command assets

The Go CLI includes `foreman commands` for generating Foreman shortcuts for AI-agent tools. It emits Claude Code project-local slash-command Markdown and Pi/OMP skills (in ~/.pi/agent/skills/). Codex and OpenCode remain generate-only copyable assets.

```bash
cd packages/foreman_cli
go run ./cmd/foreman commands inventory
go run ./cmd/foreman commands generate --agent all --output ./foreman-agent-commands
go run ./cmd/foreman commands install --agent claude --scope project
go run ./cmd/foreman commands validate
```

Generated assets call the real `foreman` CLI and inherit `FOREMAN_API_URL` / `FOREMAN_API_TOKEN`; they do not embed credentials. See [`docs/user-guide.md`](./docs/user-guide.md) and [`docs/cli-reference.md`](./docs/cli-reference.md) for support states and exact flags.

## API authentication

The Foreman JSON API (`/api/*`) is **unauthenticated by default** in development and test environments.

In production, set the `FOREMAN_API_TOKEN` environment variable to enable bearer-token authentication:

```
FOREMAN_API_TOKEN=your-secret-token
```

When set, all `/api/*` requests require an `Authorization: Bearer <token>` header. Requests without a valid bearer token receive a `401 Unauthorized` response.

To run in production without authentication (not recommended), set `allow_insecure_local: true` in the MCP policy config.

The MCP task tools expose `foreman_task_list`, `foreman_task_get`, and write-gated `foreman_task_update`. Task list supports `project_id`/canonical `status` filters plus `limit`/`offset` pagination and returns `{tasks, total, limit, offset, next_offset}`.

The MCP `foreman_task_create` write tool accepts optional `task_type` and defaults it to `"task"` when omitted.

`foreman_run_status` returns a bounded run-status DTO from run and phase projections: `run_id`, `status`, `terminal`, `project_id`, `task_id`, `workflow_name`, `current_phase`, timestamps, and `failure_reason`.

`foreman_run_get_logs` reads the Elixir projection of durable worker stdout/stderr events. Known runs with no captured output return an empty result and unknown runs return `NOT_FOUND`, so "wrote nothing" is never confused with "no such run". The read is bounded (latest 500 of at most 5,000 entries / 1 MiB retained per run) and reports eviction as `truncated: true` with non-zero `omitted_entries`.

## Build & test

The Elixir runtime (verified tests in this slice):
```
cd packages/foreman_server && mix test
```

The Go CLI:
```
cd packages/foreman_cli && go build ./...
```

The vendored Jido Harness fork:
```
cd packages/jido_harness && mix test
```

For per-package build/test commands (CLI/daemon/MCP), see each
package's `package.json`/`mix.exs`.
## Verification and development

This project includes tools for validating the README accuracy, running end-to-end smoke tests, and managing Jido upstream upgrades:

**README accuracy validator:**
```bash
bash scripts/test-readme-accuracy
```
Validates that README.md references match the actual repository structure: no legacy paths, existing packages/docs, referenced files, no duplicate headings, correct TRD identifiers, and proper module references. This script ensures the README stays synchronized with the codebase.

**End-to-end task-approval smoke test:**
```bash
bash scripts/e2e-task-approval
```
Exercises the full project → task → run → worker → projection loop through the Go CLI and Phoenix API, validating atomic task creation, approval, and run dispatch.

**Jido upstream upgrade workflow:**

The [`.github/workflows/jido-upstream-upgrade.yml`](./.github/workflows/jido-upstream-upgrade.yml) CI job runs automatically when upstream Jido releases are detected. It evaluates whether Foreman's test suite passes against new Jido commits and adopts the upgrade only when tests are green.

To manually trigger the upgrade evaluation:
```bash
bash scripts/trigger-jido-upgrade.sh
```

The evaluation logic itself lives in [`scripts/ci/jido-upgrade-evaluation.sh`](./scripts/ci/jido-upgrade-evaluation.sh) (JRM-T004): it runs the full Foreman test suite against the candidate Jido version and reports pass/fail. See [`JIDO_FORKS.md`](./JIDO_FORKS.md) for the pinned fork manifest and [`docs/user-guide.md`](./docs/user-guide.md) §7 for runtime configuration.

## Phase stall detection

Foreman supports opt-in phase stall detection through workflow phase `stall_detection` metadata. Valid values are `agent`, `agent_no_output`, `messaging`, `messaging_no_progress`, or a map with `kind`, optional positive `threshold_ms`, and optional `policy` (`fail` or `attention`). Defaults are 900000 ms for agent no-output stalls and 1800000 ms for messaging no-progress stalls. Disable the detector with `config :foreman_server, :stall_detection_enabled, false`; non-positive thresholds are malformed, not a disable shortcut.

Stalls are persisted as `RunStallReported` events via `run.report_stall`, projected to `latest_stall` on run/phase/task projections, and rendered by HTTP/MCP/CLI JSON surfaces that read those projections. Worker heartbeats keep liveness checks alive but do not count as agent output progress.
