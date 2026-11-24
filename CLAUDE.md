# CLAUDE.md — durable developer architecture conventions

This file records durable, behavior-grounded architecture decisions
for the Foreman repo. Anything that drifts from these rules without
a tracked TRD is a regression. `AGENTS.md` (the agent-context file)
is a session-level contract for coding subagents and remains authoritative for that purpose
(it was read-only to this file's authors until the jobsite retirement, which the operator
authorised it to update).

> **Layout:** this file is the index. Each section's full text lives in `docs/lessons/`; read the matching file before touching that area. `AGENTS.md` stays the session-level rules file.

## 1. The agent runtime façade is the only public mutation surface

Callers reach the runtime only through `AgentRuntime.execute/3` and `register/1` / `register_adapter/2`; nothing else starts invocations, calls `AdapterCatalog` directly, or reads the runtime's app config outside the supervisor, façade, `FailurePolicy` and per-adapter accessors.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 2. Process layering (agent runtime)

Supervision of the agent runtime (`AdapterCatalog` and `InvocationSupervisor` permanent, `Invocation` temporary) and of Overwatch's worker tree, where `LaunchWorker` is `:transient`, never `:permanent`, and its exit reason is the relaunch decision.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 3. Errors flow one way

`execute/3` returns `{:ok, text}` or one of a closed set of `{:error, ...}` shapes; the success branch never names a backend and adapter-private metadata never reaches the public result.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 4. The `BackendAdapter` behaviour

The four callbacks (`name/0`, `capabilities/0`, `available?/0`, `execute/2`): capabilities are validated at registration, `available?/0` is checked on every call, and `execute/2` runs inside the `Invocation` process.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 5. `execute/3` strategies

`:manual` (needs `backend`, never substitutes another), `:automatic` (context, availability, then cost, latency and registration order; never random) and `:policy` (`policy_module.route/2`), with per-call overrides.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 5.1 Jido Harness provider and model selection

`AgentRuntime.JidoHarness` is the provider source of truth (`:pi`, `:claude`; a LiteLLM proxy is reached through them, `:litellm` is not a provider). Phase `models.default` becomes `context.model`; `Workflow.ModelResolution` names the rule that chose it.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 6. `FailurePolicy.resolve/2` precedence

Resolution order for `:fail_fast`, `:fallback`, `:max_attempts` and `:timeout_ms`: per-call opts, per-task config, app default, built-in defaults (no default deadline). `fail_fast` is always `true`.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 7. Telemetry contract

One `[:foreman, :agent_runtime, :invocation, :complete]` event per `execute/3`, owned by the façade, with a whitelisted shape that never carries prompt text; also the span policy for coordinator-turn and workflow-phase spans.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 8. Configuration keys (operator-visible)

The `:foreman_server, :agent_runtime` keys the runtime reads (`:enabled`, `:adapters`, `:failure_policies`, `:default_timeout_ms`) and their defaults; an undocumented key is a feature request, not a bug.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 9. Adapter extension checklist (developer workflow)

Adding an adapter: implement the behaviour, register it through config or `AgentRuntime.register/1`, fix any registration error, and cover the happy path, canonical failure, `available?/0` and the no-backend-identifier rule.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 10. Things that are deliberately not in this slice

Not in the agent-runtime slice: streaming, whole-execution retry across crashes, queueing for unavailable adapters and remote backends; code that adds them inline without a TRD is out of scope.

Full text: `docs/lessons/agent-runtime-conventions.md`.

## 11. Workflow catalog is the only manifest source (Go/Elixir CQRS slice)

`Workflow.Catalog` is the single owner of every parsed manifest and prompt body (root `~/.foreman/workflows`, or `:workflow_root`): synchronous load, hot reload by polling, gated auto-install of the bundled templates, and `commit:`, `stack_pr:`, `timeout_minutes:` as phase fields.

Full text: `docs/lessons/workflow-catalog-and-worktree-contract.md`.

## 12. Foreman-managed worktree contract for implement-trd workflows (Go/Elixir CQRS slice)

The bundled `implement-trd` and `implement-trd-beads` manifests and the worktree contract they declare: worktree ownership, single-flight per TRD, Beads scope and bead id, clean-vs-dirty cleanup, and `implement-trd-beads` judged on the Beads graph.

Full text: `docs/lessons/workflow-catalog-and-worktree-contract.md`.

## 13. Task-provider boundary reminder (Go/Elixir CQRS slice)

`RunExecutor` drives claim/complete/fail as keyed `task_provider` effects (§13.2) and `Workflow.BootReconciliation` drives orphan-reopen; `set_priority` and `add_dependency` stay at the adapter boundary.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.1 Operator run dashboard boundary

`GET /dashboard/runs` (browser token plug; `/dashboard` stays the Jido live dashboard) reads only `ProjectionStore` projections, and its run-control buttons dispatch public operator envelopes through `CommandGateway.dispatch_operator/1`.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.2 Durable execution: recovery, effect keys, preflight (Phase 0)

Phase 0 durable execution (`docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md`): keyed effects, reconcilers, the boot sweep, the restart budget, kickoff preflight order, execution profile, cancellation and test hermeticity.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 13.3 Kata task provider (`ForemanServer.TaskProviders.KataAdapter`)

Provider binding is keyed on the capability `storage_scheme` (`:sqlite` Beads by `database_path`, `:cli_process` Kata by an absolute `config.cwd`) through `TaskProvider.StorageBinding`; also the Kata CLI, claim authority and doctor.

Full text: `docs/lessons/durable-execution-and-dashboard.md`.

## 14. Beads sync invariants (Go/Elixir CQRS slice)

Atomic `task.create` (the provider mints the Bead before the append), the `external_id` contract, opt-in inbound Beads sync and orphan janitor, the adapter boundary and an honest doctor; drift without a tracked TRD is a regression.

Full text: `docs/lessons/beads-sync-and-lease.md`.

## 15. Per-DB Beads lease (Go/Elixir CQRS slice)

`Aggregates.BeadsDbLease` is an event-sourced lock per absolute Beads DB path so `br`/`bv` writers never overlap: acquire-or-enqueue, release-with-promotion, process-bound holds, dead callers, fail-closed gating, compensation.

Full text: `docs/lessons/beads-sync-and-lease.md`.

## 18. Per-project run slots (per-project dispatch queues)

Run concurrency is enforced per project (stream `run_slots:<project_id>`): there is no global run-slot queue or machine-wide ceiling, and total concurrency is the sum of per-project limits (TRD-2026-b9e27ab5). Also capacity, promotion and legacy-stream migration.

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 19. Durable worker run logs and MCP run status

`foreman_run_status` is a bounded DTO over `ProjectionStore.run/1` and `phases_for_run/1`; `foreman_run_get_logs` reads `ProjectionStore`, fed only by `WorkerProtocol.emit` worker events, with bounded retention and `omitted_*` accounting.

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## Phase stall detection

`stall_detection` is explicit phase metadata normalized by `Workflow.StallPolicy`; `StallDetector` persists stalls only through `run.report_stall`, and worker heartbeats do not count as output activity.

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 20. SigNoz operational-log bridge

`Observability.OtelLogBridge` adds a `:logger` handler that exports redacted operational logs to SigNoz over OTLP/HTTP; it is separate from the Langfuse trace path (§7) and switched by four `FOREMAN_SIGNOZ_*` env vars.

Full text: `docs/lessons/run-slots-logs-and-signoz.md`.

## 20.1 Threads (Claude-Projects parity, E6)

`ForemanServer.Threads` is a pure read model over existing projections (no event backs a thread except the disposition flag). Rules cover `thread.resolve`/`thread.reopen`, live steering and its fallback, routes, `Threads.Finder` and bounded transcripts.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.2 Overview (Claude-Projects parity, E7)

`ForemanServer.Overview` is a pure read model over `Threads`, PR and merge-gate state, review verdicts and approval/question counts. Rules cover grouping, PR state folding, tabs, signals, approvals and questions (E8) and the operator-only merge gate.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.3 Scheduled tasks (E11)

`Aggregates.Schedule` with its operator and system-only commands, the typed `Schedule.Spec` (5-field cron or interval, UTC), the pure `Schedule.Planner`, the supervised `Schedule.Ticker`, read surfaces, MCP write tools and the Scheduled tab.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 20.4 Project coordinator (Claude-Projects parity, E15)

One event-sourced conversation per project (`Aggregates.Coordinator`, stream `coordinator:<project_id>`): operator versus system-only commands, the runner and agent, `Coordinator.Dispatch` as the single choke point for effects, authority, workflow selection and usage.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 21. Outbound messaging delivery

`ForemanServer.Notifier` (supervised, on by default) maps projection events to `failure`, `stall`, `action_needed` and `run_update` notifications for `Messaging.notify/2`; provider HTTP stays behind `Messaging.Providers.*`, and `Messaging.Dispatcher` redelivers at boot.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 22. Project memory

Project memory lives under `<project path>/.foreman/memory/`: content on disk, never in events (events carry metadata only). Always go through `ForemanServer.ProjectMemory`, which locks per project and redacts before writing.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 23. Standing context injection

`ForemanServer.ProjectContext.build/2` is the only producer of standing project context (instructions, repositories, provider sections such as memory); caps count characters, truncation is visible in the text, and the Repositories section is orientation only.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 24. PR watching and bounded auto-fix (E9)

`PrWatcher` folds observed PR state into the run's `pr_watch` projection (polling is the opt-in `PrMonitor`); fixes are follow-up runs under loop guards and merging stays operator-only. Also the Phase 1 entries: review findings, risk rubric, PR report, `required_checks` gate, evidence and waivers.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 25. Project library

A project's library is a read-only file store every agent of the project can use, under `<primary repo>/.foreman/library/<entry_id>/`: only `library/` is gitignored, bytes live on disk (events carry metadata only), and access goes through `ForemanServer.Library`.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 26. Claude-Projects invariants (cross-cutting contracts)

Rules that hold across every project-workspace capability (E0-E11, E13-E16), each naming its enforcing code and test: typed boundaries, operator-only merge gate, system-only commands off the operator allowlists, registered aggregate prefixes, strict `EventCodec`, no secrets or content in events.

Full text: `docs/lessons/claude-projects-invariants.md`.

## 27. Follow-up runs and the retired jobsite door

The separate jobsite dispatch path (`/api/jobsites`, `foreman jobsite`, `Jobsite.Executor`) is retired (`docs/plans/retire-jobsites.md`); its worthwhile capabilities live in runs: follow-up runs (`run.followup.request`, system-only), session resume and sandbox.

Full text: `docs/lessons/claude-projects-invariants.md`.
