---
document_id: PRD-2026-e8d3f5f2
label: prd-create-a-foreman-mcp-server-covering-all-existin
version: 0.1.0
status: Draft
date: 2026-08-10
scale_depth: STANDARD
total_requirements: 13
readiness_score: 4.1
---

# PRD: Foreman MCP Server for External Foreman Surfaces

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 3 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 13/13 (100%) |
| Risk flags | 8 |
| Dependencies | 11 |
| Open ambiguity markers | 0 |
| TRD decisions required | 4 |

## 1. Executive Summary

Foreman needs an MCP server so MCP-aware agentic clients can inspect and operate Foreman without hand-writing Phoenix HTTP clients or shelling through the Go CLI. The server must expose Foreman's existing external public surfaces as MCP tools/resources, provide useful agent-facing renderings for runs/tasks, and preserve Foreman's command-boundary invariants.

The product invariant is strict: MCP is a parallel ingress, not a new domain model. It must not introduce new Foreman domain commands, bypass bearer-token auth, or expose supervisor-owned bookkeeping commands that are currently emitted only by OTP-internal code paths.

## 2. Background and Evidence

Task `foreman-foreman-mcp-server-mmul` requests a Foreman MCP server covering all existing commands and agentic UI affordances.

Evidence from the current codebase:

- Public operator mutations are gated by `ForemanServer.CommandGateway.@allowed_operator_types` in `packages/foreman_server/lib/foreman_server/command_gateway.ex`: `project.register`, `project.update`, `project.archive`, `task.create`, `task.approve`.
- Trusted internal mutation path is `ForemanServer.CommandGateway.dispatch_system/2`, which intentionally accepts command types outside the public operator allow-list.
- Public HTTP query/admin/webhook routes live in `packages/foreman_server/lib/foreman_server_web/router.ex`: project/task/run reads, workflow install, external trigger webhook, and GitHub webhook.
- Every `/api` route uses `ForemanServerWeb.Plugs.BearerAuth` through the `:api` pipeline. Webhooks are separate routes and must keep their existing auth/signature semantics.
- Existing CLI subcommands in `packages/foreman_cli/cmd/foreman/main.go` cover project create/get/update/delete/list, task create/approve/get, run get, and workflow install.
- Aggregate command handling is spread across `packages/foreman_server/lib/foreman_server/aggregates/*.ex`; the TRD must derive the full command inventory from these files rather than memory.

## 3. Personas

### 3.1 Agentic client user

Uses Claude Code, Cline, a custom UI, or another MCP client to create/approve tasks, inspect Foreman state, watch runs, and get Markdown summaries without building a custom Foreman API adapter.

### 3.2 Foreman operator

Needs MCP access that is safe by default, auditable, authenticated, and clear about which dangerous recovery/system commands are intentionally unavailable.

### 3.3 Foreman maintainer

Needs a design that reuses existing Phoenix/CommandGateway/projection boundaries and stays easy to test when aggregate commands, HTTP routes, or CLI surfaces change.

## 4. Goals and Non-Goals

### Goals

- Expose every current Bucket A public Foreman capability through MCP tools or resources.
- Require a TRD inventory that enumerates every current `handle_command/2` command type and classifies it as Bucket A, B, or C.
- Default-deny Bucket B recovery/operator-extensible commands unless explicitly configured per command/capability.
- Forbid Bucket C system-internal commands as MCP tools.
- Provide agent-friendly resources for active runs, blocked tasks, recent failures, and run/task Markdown summaries.
- Support stdio for local agentic CLIs and Streamable HTTP for hosted/client UI integrations.
- Reuse existing bearer-token auth for MCP access; no auth bypass for local transports.
- Reconcile MCP tool/resource coverage with existing Go CLI and Phoenix HTTP surfaces.

### Non-Goals

- Adding new Foreman domain commands beyond the current CommandGateway/aggregate command vocabulary.
- Redesigning or replacing the Go CLI.
- Replacing Phoenix HTTP APIs or webhook endpoints.
- Letting MCP clients dispatch raw Bucket C commands.
- Turning recovery/scheduler/run lifecycle controls into an external API by default.
- Implementing arbitrary cross-project authorization unrelated to existing Foreman auth boundaries.

## 5. Command Exposure Buckets

The PRD defines the bucket policy. The TRD must fill the complete inventory from actual source code.

### Bucket A — External public, must be exposed

Bucket A includes capabilities reachable today without direct supervisor/OTP access:

- HTTP operator mutations allowed by `CommandGateway.@allowed_operator_types`:
  - `project.register`
  - `project.update`
  - `project.archive`
  - `task.create`
  - `task.approve`
- HTTP query/admin/webhook capabilities from `router.ex`:
  - `GET /api/projects`
  - `GET /api/projects/:id`
  - `GET /api/tasks/:id`
  - `GET /api/runs/:id`
  - `POST /api/admin/workflows/install`
  - `POST /webhooks/external_trigger`
  - `POST /webhooks/github`
- Existing Go CLI capabilities, reconciled one by one against MCP coverage:
  - `project create|get|update|delete|list`
  - `task create|approve|get`
  - `run get`
  - `workflow install`

### Bucket B — Recovery / operator-extensible, opt-in only

Bucket B includes aggregate commands handled by `handle_command/2` but not allowed by `dispatch_operator/2`, where an operator-facing recovery surface may be useful only under explicit server-side policy. Examples the TRD must confirm from source include `task.block`, `task.close`, `task.update`, `task.annotate`, `task.dispatch`, `task.add_dependency`, `project.reactivate`, `task.execution_complete`, and `task.execution_fail`.

Default policy: deny every Bucket B command unless a named MCP config allow-list entry enables that exact type or capability.

### Bucket C — System-internal, never exposed

Bucket C includes aggregate commands emitted by OTP-internal code paths for run lifecycle, phases, workers, tool calls, operator intervention, planning flow, recovery, scheduler, stream gap detection, artifacts/reports, attachments, board state, import migration, inbox, integrations, PR association, project run limits, VCS operations, and similar supervisor/projection bookkeeping.

MCP clients must not directly dispatch these commands because doing so would let external callers race the supervisor, corrupt event sequencing, fake runtime state, or bypass workflow safety checks.

## 6. Requirements

### REQ-001: Must | Critical | MCP server exists as a Foreman external integration

Foreman MUST provide an MCP server that MCP-aware clients can use to operate and inspect Foreman through supported tools/resources.

- AC-001-1: Given Foreman is configured with MCP enabled, when the server starts, then MCP clients can initialize and discover Foreman tools/resources.
- AC-001-2: Given MCP is disabled or not configured, when Foreman starts, then existing Phoenix API, worker runtime, scheduler, and Go CLI behavior remain unchanged.

### REQ-002: Must | Critical | Bucket A public mutations are exposed safely

The MCP server MUST expose all current public operator mutations from `CommandGateway.@allowed_operator_types`.

- AC-002-1: Given an MCP client invokes the public dispatch tool for `project.register`, `project.update`, `project.archive`, `task.create`, or `task.approve`, when auth succeeds and the payload is valid, then Foreman dispatches through `CommandGateway.dispatch_operator/2`.
- AC-002-2: Given a command type outside the public allow-list is submitted through the Bucket A dispatch path, when validation runs, then the server rejects it instead of routing directly to `CommandRouter`.
- AC-002-3: Given `task.approve` is invoked, when the tool returns, then the result preserves the existing approval snapshot/idempotency semantics owned by `Workflow.Approval`.

### REQ-003: Must | High | Bucket A public queries and admin/webhook capabilities are exposed

The MCP server MUST expose current public read/admin/webhook surfaces as tools or resources.

- AC-003-1: Given an MCP client requests projects, a project, a task, or a run, when auth succeeds, then the server returns structured JSON equivalent to the existing HTTP read model.
- AC-003-2: Given a client asks for workflow asset installation, when authorized, then MCP exposes the existing workflow install capability without creating a second install path.
- AC-003-3: Given external trigger or GitHub webhook functionality is exposed through MCP, when invoked, then the existing controller/security semantics are preserved or explicitly documented as not applicable for MCP input.

### REQ-004: Must | Critical | Complete command inventory is required in the TRD

The paired TRD MUST include a complete, code-derived inventory of every command type currently handled by aggregate `handle_command/2` clauses.

- AC-004-1: Given the TRD is written, when its inventory section is reviewed, then every command type found by `grep "def handle_command" packages/foreman_server/lib/foreman_server/aggregates/*.ex` is listed exactly once.
- AC-004-2: Given each listed command type, when the inventory is reviewed, then it is classified as Bucket A, Bucket B, or Bucket C with source file and rationale.
- AC-004-3: Given the known Bucket C examples in the task prompt, when the inventory is reviewed, then the TRD confirms whether each exists in current code and identifies any newly discovered internal types.

### REQ-005: Must | Critical | Bucket C never leaks into MCP tools

The MCP server MUST NOT expose Bucket C system-internal commands as direct tools.

- AC-005-1: Given a command type classified as Bucket C, when tool discovery is performed, then no MCP tool can dispatch that command type directly.
- AC-005-2: Given the Bucket A/B tool registry is built, when it is compared to the TRD inventory, then zero Bucket C command types appear in exposed dispatch allow-lists.
- AC-005-3: Given an external client attempts to submit a Bucket C type through a generic dispatch payload, when validation runs, then the request is denied before reaching `dispatch_system/2` or `CommandRouter`.

### REQ-006: Must | High | Bucket B is policy-driven and default-deny

The MCP server MUST support only explicitly enabled Bucket B recovery/operator-extensible command exposure.

- AC-006-1: Given no Bucket B config is present, when an MCP client discovers tools, then no Bucket B mutation tools are advertised.
- AC-006-2: Given a server-side allow-list enables one Bucket B type, when tool discovery runs, then only that exact type/capability is available.
- AC-006-3: Given an enabled Bucket B command is invoked, when validation runs, then the result records which capability allowed it and rejects any non-allow-listed type.

### REQ-007: Must | High | Existing auth boundary is reused

The MCP server MUST reuse Foreman's bearer-token model and must not bypass auth for local or hosted MCP transports.

- AC-007-1: Given an HTTP MCP request is missing or has an invalid bearer token, when auth is enforced, then the request is rejected consistently with the existing `/api` auth model.
- AC-007-2: Given stdio transport is used locally, when the MCP server performs Foreman operations, then it still requires configured bearer-token authorization or an explicitly documented equivalent local credential check.
- AC-007-3: Given logs/telemetry are emitted, when auth failures or tool calls are recorded, then bearer tokens and payload secrets are not logged.

### REQ-008: Must | High | Transport support covers local and hosted clients

The MCP server MUST support stdio for local agentic CLIs and Streamable HTTP for hosted or UI clients.

- AC-008-1: Given a local MCP client configures stdio, when it launches Foreman MCP, then initialization and tool calls work without requiring a separate custom HTTP wrapper.
- AC-008-2: Given a hosted or UI client uses Streamable HTTP, when it connects with valid auth, then it can initialize, list tools/resources, and invoke supported operations.
- AC-008-3: Given both transports are enabled, when they invoke the same Foreman operation, then they share the same authorization, validation, idempotency, and output contracts.

### REQ-009: Should | Medium | Tool granularity is agent-friendly but compact

The MCP surface SHOULD avoid excessive tool sprawl while keeping high-value operations discoverable.

- AC-009-1: Given a client lists tools, when public mutations are shown, then the primary command dispatch surface is compact and typed.
- AC-009-2: Given `task.approve` is a high-value workflow action with snapshot semantics, when tools are listed, then it is discoverable as a dedicated operation or prominently documented command variant.
- AC-009-3: Given the TRD selects generic dispatch, one-tool-per-command, or a hybrid model, when reviewed, then it justifies the decision against CLI parity, MCP UX, and Bucket safety.

### REQ-010: Should | Medium | Agentic UI resources are built in

The MCP server SHOULD provide resources/prompts/tools that answer common agent questions without requiring clients to compose raw API calls.

- AC-010-1: Given a client asks what Foreman is doing now, when it reads MCP resources, then active runs, blocked tasks, and recent failures are available.
- AC-010-2: Given a client inspects a task or run, when it requests rendered output, then the server can return Markdown suitable for an agentic chat UI as well as raw JSON for programmatic use.
- AC-010-3: Given a client asks “what tasks are blocked on `foreman`?”, when relevant data exists, then the server can answer with rendered Markdown using only Bucket A and enabled Bucket B capabilities.

### REQ-011: Must | Medium | Long-running run observation is supported

The MCP server MUST include a long-running or streaming observation surface for run progress.

- AC-011-1: Given a client invokes `run.watch` or equivalent, when a run changes, then the client receives progress events or periodic state updates until terminal state or timeout.
- AC-011-2: Given the observation implementation uses polling, PubSub, or event-store tailing, when the TRD is reviewed, then it documents coupling, latency, and failure tradeoffs.
- AC-011-3: Given a watch request ends, when resources are cleaned up, then no orphan subscriptions/processes remain.

### REQ-012: Must | High | MCP coverage reconciles with CLI and HTTP

The TRD and implementation MUST reconcile MCP coverage against the Go CLI and HTTP route surfaces.

- AC-012-1: Given the CLI subcommand list from `main.go` and per-resource files, when compared to MCP tools/resources, then each CLI capability has an MCP equivalent or a documented reason for exclusion.
- AC-012-2: Given the HTTP route list from `router.ex`, when compared to MCP tools/resources, then each external HTTP capability has an MCP equivalent or a documented reason for exclusion.
- AC-012-3: Given a capability exists in MCP but not the CLI, when the reconciliation is reviewed, then the difference is intentional and documented.

### REQ-013: Should | Medium | Documentation and diagnostics are updated

Foreman SHOULD document the MCP server for operators and maintainers and expose enough diagnostics to debug tool registration, auth, and command policy.

- AC-013-1: Given MCP support is implemented, when operator docs are reviewed, then setup, auth, stdio config, Streamable HTTP config, and exposed/forbidden command policy are documented.
- AC-013-2: Given a tool is denied by Bucket B/C policy, when diagnostics are inspected, then the error identifies the denied command type and policy reason without leaking sensitive payloads.
- AC-013-3: Given command inventories change in future code, when maintainers update aggregate handlers, then tests or docs make MCP exposure drift visible.

## 7. Dependencies

- Existing Phoenix API and `BearerAuth` plug.
- `ForemanServer.CommandGateway.dispatch_operator/2` and `dispatch_system/2` boundaries.
- Aggregate modules under `packages/foreman_server/lib/foreman_server/aggregates/`.
- Projection/read-model APIs for projects, tasks, and runs.
- Workflow install controller and asset installer.
- Webhook controllers and their existing security semantics.
- Go CLI source under `packages/foreman_cli/cmd/foreman/` for reconciliation.
- An MCP protocol library or small in-repo protocol implementation selected by the TRD.
- Runtime configuration for stdio, Streamable HTTP, auth, and Bucket B allow-list.
- Telemetry/logging conventions that avoid payload/token leakage.
- Documentation targets: README/user guide/CLI reference or dedicated MCP guide.

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Bucket C command leakage | External clients can race supervisors or forge runtime state | TRD inventory, explicit allow-lists, tests asserting zero Bucket C exposure |
| Generic dispatch tool too permissive | Policy bypass through arbitrary `command_type` | Validate command type before dispatch; route Bucket A only through `dispatch_operator/2` |
| Bucket B ambiguity | Recovery tools become unsafe production mutation surface | Default deny; per-type server-side allow-list; policy logged in diagnostics |
| Auth bypass on stdio | Local clients mutate Foreman without credential checks | Require bearer token or documented equivalent local credential check |
| MCP library/runtime choice adds maintenance burden | Larger ongoing dependency/support surface | TRD must choose Elixir app vs Go binary and justify least ongoing surface |
| Observation implementation over-couples to internals | Run watching becomes brittle or high-latency | TRD compares EventStore tail, PubSub subscription, and polling |
| CLI/HTTP/MCP drift | Users see inconsistent capabilities | Reconciliation table and drift tests/docs |
| Sensitive data leaks in telemetry | Tokens, payloads, or command bodies exposed | Whitelist telemetry metadata and redact payloads by default |

## 9. Success Metrics

- MCP clients can discover and invoke all Bucket A public capabilities.
- No Bucket C command type appears in MCP tool discovery or dispatch allow-lists.
- Bucket B commands are unavailable by default and become available only through explicit per-type policy.
- `run.watch` or equivalent provides useful progress observation for long-running runs.
- Agentic resources answer active-runs, blocked-tasks, and recent-failures questions without custom client code.
- CLI/HTTP/MCP reconciliation is complete in the TRD and remains testable.

## 10. TRD Decisions Required

The paired TRD must record decisions for:

1. **Server language/runtime:** Elixir Plug/Phoenix sub-app vs separate Go binary.
2. **Observation model:** EventStore tail, Phoenix PubSub, projection polling, or hybrid.
3. **Tool granularity:** generic typed dispatch, one tool per command type, or hybrid.
4. **Bucket B policy model:** server-wide allow-list vs per-client capability token, with default deny either way.

## 11. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | MCP server external integration | Must | High | 2 |
| REQ-002 | Bucket A public mutations | Must | High | 3 |
| REQ-003 | Public queries/admin/webhooks | Must | High | 3 |
| REQ-004 | Complete TRD command inventory | Must | Critical | 3 |
| REQ-005 | Bucket C never exposed | Must | Critical | 3 |
| REQ-006 | Bucket B default-deny policy | Must | High | 3 |
| REQ-007 | Existing auth boundary reused | Must | High | 3 |
| REQ-008 | stdio and Streamable HTTP | Must | High | 3 |
| REQ-009 | Compact, agent-friendly tools | Should | Medium | 3 |
| REQ-010 | Agentic UI resources | Should | Medium | 3 |
| REQ-011 | Long-running run observation | Must | Medium | 3 |
| REQ-012 | CLI/HTTP/MCP reconciliation | Must | High | 3 |
| REQ-013 | Documentation and diagnostics | Should | Medium | 3 |

## 12. Readiness Checklist

- [x] User value stated
- [x] External surfaces identified
- [x] Bucket policy stated
- [x] TRD inventory deliverable required
- [x] Bucket C non-exposure invariant stated
- [x] Bucket B default-deny behavior stated
- [x] Auth and transport requirements stated
- [x] CLI/HTTP reconciliation required
- [x] Risks captured
- [x] Dependencies listed
- [x] Paired TRD created

---

*Generated: 2026-08-10 | Document ID: PRD-2026-e8d3f5f2 | Scale: STANDARD | Draft v0.1.0*
