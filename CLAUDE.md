# CLAUDE.md — durable developer architecture conventions

This file records durable, behavior-grounded architecture decisions
for the Foreman repo. Anything that drifts from these rules without
a tracked TRD is a regression. `AGENTS.md` (the agent-context file)
is a session-level contract for coding subagents and remains authoritative for that purpose
(it was read-only to this file's authors until the jobsite retirement, which the operator
authorised it to update).

> **Layout:** this file is the index. Each section's full text lives in `docs/lessons/`; read the matching file before touching that area. `AGENTS.md` stays the session-level rules file.

## 1. The agent runtime façade is the only public mutation surface

Callers interact with the runtime **only** through `ForemanServer.AgentRuntime.execute/3` and `register/1` / `register_adapter/2`. No other module is allowed to:

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 2. Process layering (agent runtime)

``` ForemanServer.Application └── ForemanServer.AgentRuntime.Supervisor         (permanent, :one_for_one) ├── ForemanServer.AgentRuntime.AdapterCatalog  (GenServer + Registry) └── ForemanServer.AgentRuntime.InvocationSupervisor (DynamicSupervisor) └── Invocation                       (temporary — one per execute/3…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 3. Errors flow one way

Public `:execute/3` always returns one of:

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 4. The `BackendAdapter` behaviour

```elixir @callback name() :: atom() @callback capabilities() :: %{required(:type) => atom(), required(:strengths) => [...], required(:weaknesses) => [...], required(:supported_contexts) => [...], optional(:cost_per_call) => number(), optional(:typical_latency_ms) => non_neg_integer()} @callback available?() ::…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 5. `execute/3` strategies

```elixir ForemanServer.AgentRuntime.execute(prompt, context, strategy: :manual,        # | :automatic | :policy backend: :my_backend,      # required when strategy is :manual task_type: :code_review,   # required when strategy is :automatic or :policy policy_module: SomeMod,    # only for :policy timeout_ms:…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 5.1 Jido Harness provider and model selection

`ForemanServer.AgentRuntime.JidoHarness` is the supported-provider source of truth for the Jido Harness adapter. It currently accepts `:pi` and `:claude` (`@supported_providers`); string provider keys from decoded workflow context are normalized at this boundary. A LiteLLM proxy is a model dispatcher reached…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 6. `FailurePolicy.resolve/2` precedence

Resolved keys: `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 7. Telemetry contract

A **single** completion event is emitted per `execute/3` call, on `[:foreman, :agent_runtime, :invocation, :complete]`. The façade owns this emission (early-exit branches call `emit_early_exit_completion/3`; the invocation's terminal branch emits the normal-completion event). Duplicate emissions are a contract…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 8. Configuration keys (operator-visible)

App config read by the runtime:

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 9. Adapter extension checklist (developer workflow)

1. `defmodule MyApp.MyAdapter do` with `use ForemanServer.AgentRuntime.BackendAdapter` (or implement the four callbacks by hand). 2. Implement `name/0`, `capabilities/0`, `available?/0`, `execute/2`. 3. Register via config (`adapters: [...]`) or at boot: `ForemanServer.AgentRuntime.register(MyAdapter)`. 4.…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 10. Things that are deliberately not in this slice

- No streaming. Each `execute/3` is one round-trip; partial progress is not surfaced. - No retry of the entire execution across crashes. The invocation process owns attempt history; the OS process backing a crashed adapter may leak a temp file. - No queueing for unavailable adapters. An empty / unavailable catalog…

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 11. Workflow catalog is the only manifest source (Go/Elixir CQRS slice)

`ForemanServer.Workflow.Catalog` is the supervised GenServer that owns every parsed workflow manifest and prompt body in memory and keeps them in sync with the on-disk root (`~/.foreman/workflows` by default, overridable via `config :foreman_server, :workflow_root` — `AssetCatalog.default/0` reads that key before…

Full text: `docs/lessons/workflow-catalog-and-worktree-contract.md`.

## 12. Foreman-managed worktree contract for implement-trd workflows (Go/Elixir CQRS slice)

Foreman bundles two workflow manifests at `packages/foreman_server/priv/defaults/workflows/`: `implement-trd.yaml` and `implement-trd-beads.yaml`. Both declare the worktree schema, register with `ForemanServer.WorkflowTemplate.Installer` (`@template_names`), and are deployed by `foreman init --force`. The CLI…

Full text: `docs/lessons/workflow-catalog-and-worktree-contract.md`.

## 13. Task-provider boundary reminder (Go/Elixir CQRS slice)

RunExecutor drives claim/complete/fail, each as a keyed `task_provider` effect (§13.2). Workflow.BootReconciliation drives orphan-reopen. `set_priority` and `add_dependency` stay at the adapter boundary until a separate operator surface TRD introduces them.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.1 Operator run dashboard boundary

The run-management dashboard is `GET /dashboard/runs`, guarded by the existing browser `:require_authenticated` token plug. Keep `/dashboard` as the separate Jido live dashboard. The run dashboard reads only `ProjectionStore` projections (runs, phases, tasks, logs, worktrees, PR associations) through…

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.2 Durable execution: recovery, effect keys, preflight (Phase 0)

Source of truth: `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md`.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.3 Kata task provider (`ForemanServer.TaskProviders.KataAdapter`)

- **Binding is provider-conditional, keyed on the capability `storage_scheme`.** `:sqlite` (Beads) binds by `task_provider.config.database_path`; `:cli_process` (Kata, provider id `kata`, contract `kata.capabilities.v1`) binds by an absolute `config.cwd`. `ForemanServer.TaskProvider.StorageBinding` is the one place…

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 14. Beads sync invariants (Go/Elixir CQRS slice)

Atomic `task.create` and bidirectional Beads sync are governed by these invariants. Drift without a tracked TRD is a regression.

Full text: `docs/lessons/beads-sync-and-lease.md`.

## 15. Per-DB Beads lease (Go/Elixir CQRS slice)

SQLite's single-writer protocol cannot tolerate concurrent `br`/`bv` writers or writers running alongside `bv --robot-plan`. The `ForemanServer.Aggregates.BeadsDbLease` aggregate is an event-sourced lock keyed by the configured absolute Beads DB path passed at acquire time, giving process-local serialization…

Full text: `docs/lessons/beads-sync-and-lease.md`.

## 18. Per-project run slots (per-project dispatch queues)

Run concurrency is enforced per project; there is no global run-slot queue and no machine-wide ceiling. Total concurrency is the sum of per-project limits (TRD-2026-b9e27ab5).

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 19. Durable worker run logs and MCP run status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and `ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event streams, and keep `foreman_run_get`'s full projection shape distinct. A run id with no run projection yet falls back to `ProjectionStore.pending_run/1`: a run…

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## Phase stall detection

`stall_detection` is explicit phase metadata, never inferred from phase names. Normalize it through `ForemanServer.Workflow.StallPolicy`; valid scopes are agent/no-output and messaging/no-progress. `RunExecutor` copies normalized policy onto `phase.start`/`PhaseStarted`, `ProjectionStore.stall_candidates/1` is the…

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 20. SigNoz operational-log bridge

`ForemanServer.Observability.OtelLogBridge` installs an additional Erlang `:logger` handler (never replaces the default console handler) that exports redacted operational logs to SigNoz over OTLP/HTTP. It is deliberately separate from the Langfuse LLM-trace path (`jido_otel`/`opentelemetry_exporter`, §7 above) —…

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 20.1 Threads (Claude-Projects parity, E6)

`ForemanServer.Threads` is a pure read model over existing projections (task, run, worktree, PR association, review, and legacy jobsite history); no event backs a thread except the disposition flag. Rules:

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.2 Overview (Claude-Projects parity, E7)

`ForemanServer.Overview` is the operator's glance at a project: a pure read model over `Threads`, the PR / merge-gate state folded into `ProjectionStore`, review verdicts and approval / question counts (`Overview.Signals`). Rules:

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.3 Scheduled tasks (E11)

- `Aggregates.Schedule` (`schedule:<project_id>:<schedule_id>`): operator commands `schedule.create|update|pause|resume|delete` (allowlisted in `CommandGateway` and `CommandController`; the controller/gateway derive the composite id, `schedule.create` without an id generates `sch-<hex>`), system commands…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.4 Project coordinator (Claude-Projects parity, E15)

- One event-sourced conversation per project, stream `coordinator:<project_id>` (`Aggregates.Coordinator`). Operator-allowed commands: `coordinator.message`, `coordinator.restart` (the one allowlist in `CommandGateway`, which `CommandController` reads; add the type to the controller's…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 21. Outbound messaging delivery

`ForemanServer.Notifier` (supervised, started by default; `config :foreman_server, :start_notifier?, false` stops it) is the production producer of `Messaging.notify/2`. It subscribes to projection events (no replay) and maps them through the table in `ForemanServer.Notifier.Mapping`: run (and legacy jobsite)…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 22. Project memory

A project keeps agent- and operator-written memory under `<project path>/.foreman/memory/` (`MEMORY.md` index plus one `<topic>.md` per topic). Content lives on disk, never in events: `ProjectMemoryWritten` / `ProjectMemoryForgotten` (stream `project_memory:<project_id>`, `Aggregates.ProjectMemory`) carry metadata…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 23. Standing context injection

`ForemanServer.ProjectContext.build/2` is the ONLY producer of standing project context (instructions, repositories, provider sections such as `ProjectContext.Memory`); never assemble it elsewhere. Config `:foreman_server, :project_context` (`max_chars`, `section_caps`, `section_providers`); every cap and the total…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 24. PR watching and bounded auto-fix (E9)

`ForemanServer.PrWatcher` (config `:pr_watcher`, `enabled: false` or `FOREMAN_PR_WATCHER_ENABLED=false` stops it) folds observed PR state into the run's `pr_watch` projection through typed events `PrChecksChanged`, `PrReviewChanged`, `PrFixRequested`, `PrFixStarted`, `PrFixFinished`, `PrFixExhausted`, `PrCreated`,…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 25. Project library

A project's library is a read-only file store every agent of the project can use (Claude "Project knowledge" parity), at `<project primary repo>/.foreman/library/<entry_id>/{entry.json,files/...}`. ONLY `library/` is gitignored (`ForemanDir.ensure_ignored(path, "library/")`); `.foreman/Dockerfile`, `bead.exs` and…

Full text: `docs/lessons/claude-projects-invariants.md`.

## 26. Claude-Projects invariants (cross-cutting contracts)

Rules that hold across every project-workspace capability (E0-E11, E13-E16). Each names its enforcing code and the test that pins it; a change that weakens one needs the operator's explicit word.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 27. Follow-up runs and the retired jobsite door

The separate "jobsite" dispatch path (`/api/jobsites`, `foreman jobsite`, `Jobsite.Executor`) is retired (plan and decisions: `docs/plans/retire-jobsites.md`). Its worthwhile capabilities live in runs:

Full text: `docs/lessons/claude-projects-invariants.md`.
