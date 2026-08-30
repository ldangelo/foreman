---
document_id: TRD-2026-e8d3f5f2
label: trd-create-a-foreman-mcp-server-covering-all-existin
prd: docs/PRD/PRD-2026-e8d3f5f2-create-a-foreman-mcp-server-covering-all-existin.md
version: 1.0.0
status: Draft
date: 2026-08-10
design_readiness_score: 4.2
kind: trd
---

# TRD: Foreman MCP Server for Existing External Surfaces

## Document Purpose

Define the technical design for an in-repo Foreman MCP server. The server exposes existing safe Foreman external capabilities as MCP tools/resources, preserves CommandGateway/auth boundaries, and documents a complete code-derived command inventory for every aggregate `handle_command/2` command type.

## PRD Validation Summary

| Check | Result |
|---|---|
| Source PRD | `docs/PRD/PRD-2026-e8d3f5f2-create-a-foreman-mcp-server-covering-all-existin.md` |
| PRD status | Draft |
| Requirement coverage | REQ-001 through REQ-013 mapped below |
| Must requirements | Covered by architecture, policy, tests, and docs slices |
| Command inventory source | `packages/foreman_server/lib/foreman_server/aggregates/*.ex` `def handle_command/2` scan |
| Public operator allow-list | `CommandGateway.@allowed_operator_types`: 5 types |
| Inventory count | 98 unique aggregate command types |

Validation commands used for inventory:

```text
rg -n "def handle_command|type: \"" packages/foreman_server/lib/foreman_server/aggregates/*.ex
python3 scan of aggregate handle_command clauses and guarded `type in [...]` lists
```

## Architecture Decisions

### Decision 1 — Server language/runtime: Elixir Phoenix sub-app

Build MCP in `packages/foreman_server` as an Elixir/Phoenix subsystem.

Reason:

- Reuses `CommandGateway.dispatch_operator/2`, projection reads, telemetry, and config directly.
- Avoids a second Go binary reimplementing auth, projection clients, and event/run observation.
- Keeps Bucket B/C policy close to the aggregate command inventory and tests.
- Streamable HTTP can live under Phoenix; stdio can run as an escript/Mix task that starts the same OTP app and MCP handler.

Rejected: separate Go binary. It isolates MCP dependencies, but duplicates Foreman auth/read/write contracts and increases drift risk.

### Decision 2 — Observation model: projection polling first, PubSub optional later

Use projection polling for v1 `run.watch` and resources.

- `run.watch` polls the run projection by id with configurable interval/timeout and emits MCP progress messages/deltas.
- Resources (`active_runs`, `blocked_tasks`, `recent_failures`) read projections only.
- Future PubSub/EventStore tail support may be added behind the same watcher behaviour after stable projection contracts exist.

Reason: lowest coupling to EventStore internals and supervisor lifecycle. Latency is acceptable for agentic clients; polling failures are easy to test and bound.

### Decision 3 — Tool granularity: hybrid

Use a compact typed public dispatch tool plus discoverable dedicated tools for common UX paths.

- `foreman.command.dispatch_public`: accepts only Bucket A operator command types.
- `foreman.task.approve`: dedicated tool because approval has enrichment/snapshot semantics and high agent UX value.
- Read/query tools/resources remain separate (`project.list`, `project.get`, `task.get`, `run.get`, `run.watch`).
- Bucket B tools are generated only from explicit per-type config and never share the Bucket A dispatch path.

Reason: compact surface without generic policy bypass. `task.approve` remains visible.

### Decision 4 — Bucket B default policy: server-side per-type allow-list

Bucket B commands are denied by default. Config enables exact types only:

```elixir
config :foreman_server, :mcp,
  enabled: true,
  bucket_b_allow: ["task.annotate", "project.reactivate"]
```

No wildcard in v1. Each enabled type gets its own advertised tool/capability and audit metadata. Per-client capability tokens are deferred until Foreman has client identity beyond bearer-token auth.

## System Architecture

| Component | Responsibility | Target files |
|---|---|---|
| `ForemanServer.MCP` | Public façade: config, tool registry, dispatch/read helpers | `packages/foreman_server/lib/foreman_server/mcp.ex` |
| `ForemanServer.MCP.Policy` | Bucket A/B/C inventory, allow-list validation, no-C leakage checks | `packages/foreman_server/lib/foreman_server/mcp/policy.ex` |
| `ForemanServer.MCP.Auth` | Shared bearer-token verifier used by HTTP and stdio transports | `packages/foreman_server/lib/foreman_server/mcp/auth.ex` |
| `ForemanServer.MCP.Router` | Streamable HTTP MCP route/Plug integration | `packages/foreman_server/lib/foreman_server_web/mcp_router.ex` or Phoenix route module |
| `ForemanServer.MCP.Stdio` | Local stdio MCP entrypoint using same handler/auth/policy | `packages/foreman_server/lib/foreman_server/mcp/stdio.ex` |
| `ForemanServer.MCP.Tools` | Tool definitions and result schemas | `packages/foreman_server/lib/foreman_server/mcp/tools.ex` |
| `ForemanServer.MCP.Resources` | Active runs, blocked tasks, recent failures, rendered Markdown | `packages/foreman_server/lib/foreman_server/mcp/resources.ex` |
| `ForemanServer.MCP.Watch` | Projection polling for `run.watch` | `packages/foreman_server/lib/foreman_server/mcp/watch.ex` |
| Tests | Policy, auth, dispatch, resources, transport smoke | `packages/foreman_server/test/foreman_server/mcp/*_test.exs` |
| Docs | Setup, auth, exposed/forbidden commands | `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, optional `docs/mcp.md` |

### Transport shape

- **Streamable HTTP:** Phoenix route under `/mcp` or `/api/mcp`, protected by bearer auth. Route reuses the same token verifier as `/api`.
- **stdio:** local executable/Mix task starts the OTP app, reads a bearer token from MCP client env/config, validates it with the same verifier, then serves MCP over stdin/stdout. No unauthenticated local bypass.

### Auth design

Refactor or wrap the existing bearer-token logic so both HTTP and stdio call one verifier:

```elixir
ForemanServer.MCP.Auth.authorize!(provided_token)
```

HTTP still uses a Plug; stdio validates during MCP initialize and again before tool calls. Logs never include token or full command payload.

## MCP Surface

### Always-on Bucket A tools/resources

| MCP name | Backing Foreman surface | Result |
|---|---|---|
| `foreman.command.dispatch_public` | `CommandGateway.dispatch_operator/2` for `project.register`, `project.update`, `project.archive`, `task.create`, `task.approve` | JSON `{status,result}` |
| `foreman.task.approve` | `CommandGateway.dispatch_operator/2`, `task.approve` | JSON + Markdown summary |
| `foreman.project.list` / resource `foreman://projects` | `GET /api/projects` equivalent projection read | JSON/Markdown |
| `foreman.project.get` | `GET /api/projects/:id` equivalent | JSON/Markdown |
| `foreman.task.get` | `GET /api/tasks/:id` equivalent | JSON/Markdown |
| `foreman.run.get` | `GET /api/runs/:id` equivalent | JSON/Markdown |
| `foreman.workflow.install` | `WorkflowInstallController.install` service path | JSON |
| `foreman.external_trigger.submit` | Existing external trigger webhook semantics, not raw command dispatch | JSON accepted/rejected |
| `foreman.github_webhook.submit` | Existing GitHub webhook semantics, including signature/security handling where configured | JSON accepted/rejected |
| `foreman.run.watch` | Run projection polling | MCP progress stream/deltas |
| `foreman://runs/active` | Projection query | Markdown + JSON |
| `foreman://tasks/blocked` | Projection query | Markdown + JSON |
| `foreman://failures/recent` | Projection query | Markdown + JSON |

### Bucket B opt-in tools

Each configured type gets a distinct tool name, e.g. `foreman.system.task_annotate`. Invocation path uses `CommandGateway.dispatch_system/2` only after `MCP.Policy.allow_bucket_b?(type)` passes. Denials happen before `CommandRouter`.

### Bucket C invariant

No Bucket C command type appears in MCP tool discovery, Bucket A dispatch enum, or Bucket B allow-list output. Route-backed tools such as `foreman.external_trigger.submit` may call existing controller/service semantics, but they do not expose raw Bucket C command dispatch.

## Complete Command Inventory

Source: `packages/foreman_server/lib/foreman_server/aggregates/*.ex`, `def handle_command/2` clauses. Bucket A means public raw command dispatch via MCP. Bucket B means optional exact-type system tool. Bucket C means never raw MCP dispatch.

### Bucket A — public operator command types

| Type | Source | Rationale |
|---|---|---|
| `project.register` | `aggregates/project.ex:97`; allow-list `command_gateway.ex:41` | Public project creation mutation; CLI `project create`; expose via `dispatch_public` |
| `project.update` | `aggregates/project.ex:118`; allow-list `command_gateway.ex:41` | Public project update mutation; CLI `project update`; expose via `dispatch_public` |
| `project.archive` | `aggregates/project.ex:135`; allow-list `command_gateway.ex:41` | Public soft-delete/archive mutation; CLI `project delete`; expose via `dispatch_public` |
| `task.create` | `aggregates/task.ex:149`; allow-list `command_gateway.ex:41` | Public task creation; CLI `task create`; expose via `dispatch_public` |
| `task.approve` | `aggregates/task.ex:183`; allow-list `command_gateway.ex:41` | Public approval mutation with gateway enrichment; CLI `task approve`; expose via `dispatch_public` and dedicated tool |

### Bucket B — recovery/operator-extensible, opt-in only

| Type | Source | Default policy | Rationale |
|---|---|---|---|
| `project.reactivate` | `aggregates/project.ex:149` | Deny unless `bucket_b_allow` includes exact type | Operator recovery for archived project; not public today |
| `task.block` | `aggregates/task.ex:211` | Deny unless exact allow | Operator/provider terminal-ish state repair; can affect scheduler |
| `task.close` | `aggregates/task.ex:211` | Deny unless exact allow | Provider completion/repair; can close work without executor |
| `task.update` | `aggregates/task.ex:227` | Deny unless exact allow | Generic task state mutation; unsafe as public raw tool |
| `task.annotate` | `aggregates/task.ex:241` | Deny unless exact allow | Low-risk operator note when explicitly enabled |
| `task.dispatch` | `aggregates/task.ex:258` | Deny unless exact allow | Starts execution state from approved task; races executor if casual |
| `task.execution_complete` | `aggregates/task.ex:275` | Deny unless exact allow | Executor completion acknowledgement; only recovery should invoke |
| `task.execution_fail` | `aggregates/task.ex:291` | Deny unless exact allow | Executor failure acknowledgement; only recovery should invoke |
| `task.add_dependency` | `aggregates/task.ex:308` | Deny unless exact allow | Mutates scheduling graph; operator-only if enabled |

### Bucket C — system-internal, never exposed as raw MCP dispatch

| Type | Source | Rationale |
|---|---|---|
| `phase.report.produce` | `aggregates/artifact_report.ex:66` | Phase artifact/report lifecycle; emitted by phase completion path |
| `phase.verdict` | `aggregates/artifact_report.ex:79` | Phase verdict bookkeeping; supervisor-owned |
| `attach.request` | `aggregates/attachment.ex:52` | Worker tool-call attachment lifecycle |
| `attach.unsupported` | `aggregates/attachment.ex:65` | Worker attachment fallback bookkeeping |
| `board_item.create` | `aggregates/board_item_state_machine.ex:69` | Internal board projection/state machine transition |
| `board_item.transition` | `aggregates/board_item_state_machine.ex:87` | Internal board projection/state machine transition |
| `external.trigger` | `aggregates/external_trigger.ex:42` | Webhook controller-owned ingestion; expose route semantics only, not raw command |
| `external.accept` | `aggregates/external_trigger.ex:54` | Internal external-trigger acceptance state |
| `external.worker.observe` | `aggregates/external_trigger.ex:67` | Worker observation bookkeeping |
| `migration.import.start` | `aggregates/import_migration.ex:46` | Migration importer lifecycle |
| `migration.record.import` | `aggregates/import_migration.ex:58` | Migration importer per-record bookkeeping |
| `migration.import.complete` | `aggregates/import_migration.ex:71` | Migration importer lifecycle |
| `inbox.send` | `aggregates/inbox_thread.ex:68` | Inter-agent messaging runtime; not Foreman MCP command surface |
| `inbox.delivery.update` | `aggregates/inbox_thread.ex:83` | Inbox delivery bookkeeping |
| `integration.ingest` | `aggregates/integration.ex:59` | Integration supervisor/dedupe ingestion |
| `integration.configure` | `aggregates/integration.ex:72` | Integration supervisor configuration command |
| `integration.sync.request` | `aggregates/integration.ex:84` | Integration sync lifecycle |
| `integration.sync.complete` | `aggregates/integration.ex:84` | Integration sync lifecycle |
| `operator.needs` | `aggregates/operator_intervention.ex:58` | Agent runtime/supervisor intervention signal |
| `operator.interrupt` | `aggregates/operator_intervention.ex:58` | Runtime interruption signal |
| `operator.resume` | `aggregates/operator_intervention.ex:74` | Runtime resume signal |
| `phase.start` | `aggregates/phase.ex:65` | RunExecutor phase lifecycle |
| `phase.complete` | `aggregates/phase.ex:80` | RunExecutor phase lifecycle |
| `phase.fail` | `aggregates/phase.ex:80` | RunExecutor phase lifecycle |
| `phase.timeout` | `aggregates/phase.ex:80` | RunExecutor phase lifecycle |
| `phase.retry` | `aggregates/phase.ex:80` | RunExecutor phase lifecycle |
| `phase.skip` | `aggregates/phase.ex:80` | RunExecutor phase lifecycle |
| `planning.start` | `aggregates/planning_flow.ex:47` | Workflow/planning worker lifecycle |
| `plan.prd` | `aggregates/planning_flow.ex:47` | Plan phase start alias; internal planning flow |
| `plan.trd` | `aggregates/planning_flow.ex:47` | Plan phase start alias; internal planning flow |
| `planning.command` | `aggregates/planning_flow.ex:60` | Planning worker command record |
| `planning.trace.link` | `aggregates/planning_flow.ex:72` | Planning traceability record |
| `planning.complete` | `aggregates/planning_flow.ex:84` | Planning lifecycle terminal record |
| `pr.associate` | `aggregates/pr_association.ex:49` | PRMonitor association bookkeeping |
| `project.reserve_run` | `aggregates/project.ex:163` | RunAdmission concurrency reservation |
| `project.release_run_reservation` | `aggregates/project.ex:193` | RunAdmission reservation cleanup |
| `run_limit.reserve` | `aggregates/project_run_limit.ex:63` | Project run-limit supervisor state |
| `run_limit.release` | `aggregates/project_run_limit.ex:85` | Project run-limit supervisor state |
| `recovery.detected` | `aggregates/recovery.ex:76` | Overwatch/recovery observation |
| `recovery.observe_external_worker` | `aggregates/recovery.ex:88` | Recovery chain observation |
| `recovery.require` | `aggregates/recovery.ex:88` | Recovery chain action request |
| `recovery.reattach` | `aggregates/recovery.ex:88` | Recovery action owned by Operations |
| `recovery.restart` | `aggregates/recovery.ex:88` | Recovery action owned by Operations |
| `recovery.needs_operator` | `aggregates/recovery.ex:88` | Recovery-to-operator signal |
| `recovery.resolve` | `aggregates/recovery.ex:88` | Recovery lifecycle terminal record |
| `run.start` | `aggregates/run.ex:182` | RunAdmission/RunExecutor lifecycle |
| `run.update` | `aggregates/run.ex:204` | Supervisor-owned run metadata mutation |
| `run.delete` | `aggregates/run.ex:220` | Operations cleanup; not public raw tool |
| `run.complete` | `aggregates/run.ex:240` | RunExecutor terminal lifecycle |
| `run.pause` | `aggregates/run.ex:281` | Crash/recovery lifecycle |
| `run.cancel` | `aggregates/run.ex:298` | Operations lifecycle control |
| `run.fail` | `aggregates/run.ex:316` | RunExecutor terminal lifecycle |
| `run.block` | `aggregates/run.ex:316` | RunExecutor/blocker lifecycle |
| `run.flag_stuck` | `aggregates/run.ex:335` | StuckDetector signal |
| `run.pr.update` | `aggregates/run.ex:352` | PRMonitor/VCS lifecycle |
| `run.pr.ready` | `aggregates/run.ex:352` | PRMonitor/VCS lifecycle |
| `run.pr.retarget` | `aggregates/run.ex:352` | PRMonitor/VCS lifecycle |
| `run.pr.reset` | `aggregates/run.ex:352` | PRMonitor/VCS lifecycle |
| `run.pr.merge` | `aggregates/run.ex:352` | PRMonitor/VCS lifecycle |
| `run.recovery_event` | `aggregates/run.ex:383` | Recovery scanner ordering event |
| `scheduler.tick` | `aggregates/scheduler.ex:68` | Scheduler supervisor heartbeat |
| `scheduler.claim` | `aggregates/scheduler.ex:79` | Scheduler claim lifecycle |
| `scheduler.skip` | `aggregates/scheduler.ex:93` | Scheduler skip lifecycle |
| `scheduler_intent.record` | `aggregates/scheduler_intent.ex:91` | Scheduler intent state |
| `scheduler_intent.confirm` | `aggregates/scheduler_intent.ex:103/108` | Scheduler intent state |
| `scheduler_intent.skip` | `aggregates/scheduler_intent.ex:120/125` | Scheduler intent state |
| `scheduler_intent.mark_stale` | `aggregates/scheduler_intent.ex:137/142` | Scheduler intent staleness |
| `stream_gap.report` | `aggregates/stream_gap_detector.ex:56` | Projection reconciliation detector |
| `stream_gap.resolve` | `aggregates/stream_gap_detector.ex:77` | Projection reconciliation detector |
| `tool.request` | `aggregates/tool_call.ex:67` | Agent runtime tool policy lifecycle |
| `tool.approve` | `aggregates/tool_call.ex:79` | Agent runtime tool policy decision |
| `tool.deny` | `aggregates/tool_call.ex:79` | Agent runtime tool policy decision |
| `tool.finish` | `aggregates/tool_call.ex:94` | Agent runtime tool policy lifecycle |
| `vcs.worktree.create` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.worktree.clean` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.merge.request` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.pr.observe` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.pr.merge` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.merge.fail` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs.merge.block` | `aggregates/vcs_operation.ex:109` | VCS adapter operation lifecycle |
| `vcs_operation.start` | `aggregates/vcs_operation.ex:143` | VCS operation projection lifecycle |
| `vcs_operation.complete` | `aggregates/vcs_operation.ex:155` | VCS operation projection lifecycle |
| `vcs_operation.fail` | `aggregates/vcs_operation.ex:167` | VCS operation projection lifecycle |
| `worker.record` | `aggregates/worker.ex:239` | Worker runtime heartbeat/status record |

Inventory cross-check: 5 Bucket A + 9 Bucket B + 84 Bucket C = 98 unique command types. Zero Bucket C types are in the Bucket A public dispatch enum or Bucket B default allow-list.

## CLI / HTTP / MCP Reconciliation

### CLI parity

| CLI capability | Existing backing | MCP equivalent | Notes |
|---|---|---|---|
| `project create` | `POST /api/commands`, `project.register` | `foreman.command.dispatch_public` / optional `foreman.project.register` alias | Covered |
| `project get <id>` | `GET /api/projects/:id` | `foreman.project.get` | Covered |
| `project update <id>` | `POST /api/commands`, `project.update` | `foreman.command.dispatch_public` | Covered |
| `project delete <id>` | `POST /api/commands`, `project.archive` | `foreman.command.dispatch_public` | Covered as archive |
| `project list` | `GET /api/projects` | `foreman.project.list` / `foreman://projects` | Covered |
| `task create` | `POST /api/commands`, `task.create` | `foreman.command.dispatch_public` | Covered |
| `task approve` | `POST /api/commands`, `task.approve` | `foreman.task.approve` and dispatch | Covered; dedicated tool required |
| `task get <id>` | `GET /api/tasks/:id` | `foreman.task.get` | Covered |
| `run get <id>` | `GET /api/runs/:id` | `foreman.run.get` | Covered |
| `workflow install` | `POST /api/admin/workflows/install` | `foreman.workflow.install` | Covered |

CLI gaps relative to MCP: `run.watch`, active runs, blocked tasks, recent failures, webhook submit tools. These are intentional MCP agentic affordances; no CLI redesign required.

### HTTP parity

| HTTP route | MCP equivalent | Notes |
|---|---|---|
| `POST /api/commands` | `foreman.command.dispatch_public` | Only Bucket A public operator types accepted |
| `GET /api/projects` | `foreman.project.list` / `foreman://projects` | Covered |
| `GET /api/projects/:id` | `foreman.project.get` | Covered |
| `GET /api/tasks/:id` | `foreman.task.get` | Covered |
| `GET /api/runs/:id` | `foreman.run.get` | Covered |
| `POST /api/admin/workflows/install` | `foreman.workflow.install` | Covered |
| `POST /webhooks/external_trigger` | `foreman.external_trigger.submit` | Exposes controller semantics, not raw `external.trigger` dispatch |
| `POST /webhooks/github` | `foreman.github_webhook.submit` | Preserve signature/security semantics where configured |

## Worked Agentic Example

Question: “what tasks are blocked on `foreman`?”

1. Client reads `foreman://tasks/blocked?project_id=foreman` or invokes `foreman.tasks.blocked`.
2. MCP resource queries task projections for `project_id=foreman` and `status=blocked`.
3. Server returns JSON plus Markdown:

```markdown
## Blocked tasks for `foreman`

| Task | Title | Reason | Last update |
|---|---|---|---|
| foreman-123 | Fix runner | waiting on PR gate | 2026-08-10T10:00:00Z |

Next safe actions:
- inspect task: `foreman.task.get({"task_id":"foreman-123"})`
- approve/dispatch only if policy allows the needed mutation
```

This uses Bucket A reads/resources only. If `task.annotate` is enabled as Bucket B, the response may also suggest an annotation tool; otherwise no Bucket B tool is advertised.

## Requirement Mapping

| PRD req | Design coverage | Tests |
|---|---|---|
| REQ-001 | MCP subsystem and transports | transport init smoke tests |
| REQ-002 | `dispatch_public` validates Bucket A and calls `dispatch_operator/2` | command policy + dispatch tests |
| REQ-003 | Query/admin/webhook tools | resource/controller-adapter tests |
| REQ-004 | Inventory above | inventory drift test against aggregate source |
| REQ-005 | Bucket C deny invariant | policy test asserts no C in exposed tools/allow-lists |
| REQ-006 | Bucket B per-type allow-list | config matrix tests |
| REQ-007 | shared auth verifier | HTTP + stdio auth tests |
| REQ-008 | stdio + Streamable HTTP | transport smoke tests |
| REQ-009 | hybrid tool granularity | registry snapshot test |
| REQ-010 | agentic resources | Markdown/JSON resource tests |
| REQ-011 | `run.watch` polling | watcher timeout/terminal/delta tests |
| REQ-012 | CLI/HTTP reconciliation | static reconciliation test/docs check |
| REQ-013 | docs/diagnostics | doc updates + telemetry/error tests |

## Implementation Plan

### Slice 1 — MCP policy and inventory guard

- Add `ForemanServer.MCP.Policy` with hard-coded generated inventory matching this TRD.
- Add tests that scan aggregate `handle_command/2` clauses and fail if command types drift.
- Assert exposed Bucket A = `CommandGateway.@allowed_operator_types` and Bucket C never appears in exposed registries.

### Slice 2 — Auth and transports

- Extract/wrap bearer token verification for reuse.
- Add Streamable HTTP endpoint behind Phoenix auth.
- Add stdio entrypoint that requires configured token and shares the same MCP handler.

### Slice 3 — Bucket A tools/resources

- Implement `dispatch_public`, dedicated `task.approve`, project/task/run read tools, workflow install, webhook adapter tools.
- Auto-generate idempotency keys when omitted and return/surface them in results.
- Preserve `task.approve` gateway enrichment; reject reserved payload fields as today.

### Slice 4 — Agentic UI resources and watch

- Add projection-backed resources for active runs, blocked tasks, recent failures.
- Add Markdown renderers for task/run/project summaries.
- Add `run.watch` polling with timeout and terminal-state stop.

### Slice 5 — Bucket B opt-in

- Add exact per-type config for the 9 Bucket B commands.
- Generate one tool per enabled type.
- Route via `dispatch_system/2` only after policy approval; log capability metadata.

### Slice 6 — Docs and diagnostics

- Add operator docs for stdio/HTTP setup, bearer token config, exposed commands, Bucket B allow-list, and forbidden Bucket C rationale.
- Update CLI/user docs only to describe MCP as parallel ingress; do not redesign CLI.

## Test Plan

- Unit: `MCP.Policy` bucket classification, allow-list, inventory drift.
- Unit: tool schema validation, idempotency-key generation, Bucket B deny/allow.
- Integration: `dispatch_public` calls `CommandGateway.dispatch_operator/2`; non-A type rejected.
- Integration: stdio initialize without token fails; valid token succeeds.
- Integration: Streamable HTTP without bearer fails; valid bearer lists tools.
- Resource tests: active/blocked/recent projections produce JSON and Markdown.
- Watch tests: polling emits initial state, deltas, terminal stop, timeout cleanup.
- Snapshot/static: CLI and HTTP reconciliation tables stay in sync with source route/CLI inventory.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Bucket C leak through generic dispatch | Policy validates before dispatch; tests compare registry against inventory |
| stdio auth bypass | stdio requires same token verifier at initialize and tool-call time |
| Projection polling load | Configurable interval/timeout; bounded watchers; no infinite subscriptions |
| Webhook semantic drift | Adapter calls existing controller/service code; no raw `external.*` command tool |
| Bucket B misuse | Default deny, exact allow-list, no wildcard, diagnostic audit metadata |
| Inventory drift | Static test fails when aggregate commands change without policy update |

## Open Follow-ups for Implementation

- Pick exact Elixir MCP protocol library or minimal protocol module after dependency review.
- Confirm projection query helpers for active runs, blocked tasks, and recent failures; add read-model functions if missing.
- Decide exact HTTP mount path (`/mcp` vs `/api/mcp`) during implementation.

## Acceptance Checklist

- [x] TRD exists under `docs/TRD/`.
- [x] Inventory enumerates 98 unique `handle_command/2` types from aggregate source.
- [x] Every inventory row has A/B/C classification and rationale.
- [x] Bucket B types and exact allow-list policy are explicit.
- [x] Bucket C non-exposure invariant is stated and testable.
- [x] CLI and HTTP surfaces reconciled.
- [x] Agentic UI resources and worked blocked-task example included.
- [x] Architecture decisions recorded for language, observation, granularity, Bucket B policy.

---

*Generated: 2026-08-10 | Document ID: TRD-2026-e8d3f5f2 | Paired PRD: PRD-2026-e8d3f5f2 | Draft v1.0.0*
