---
document_id: PRD-2026-b09923de
label: prd-create-a-prd-trd-for-intercomm-style-inter-agent
version: 1.0.0
status: Draft
date: 2026-08-10
scale_depth: STANDARD
total_requirements: 15
readiness_score: 3.5
---

# PRD: Elixir Inter-Agent Communication Server

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| AC coverage | 15/15 (100%) |
| Risk flags | 7 |
| Dependencies | 12 |
| Open ambiguity markers | 13 |

## 1. Executive Summary

Foreman needs an in-repo Elixir communication server for targeted inter-agent messaging. It should support pi-intercom-style direct session discovery, send, ask/reply, pending asks, and local broker behavior, but must be implemented as Foreman's own OTP service instead of depending on `pi-intercom`.

The first consumer is expected to be Foreman/Pi worker agents coordinating local or supervised work [NEEDS CLARIFICATION: Which concrete Foreman processes are in scope for v1: Pi workers only, all agent-runtime adapters, external CLI clients, or Web UI clients?].

## 2. Background and Evidence

### Product prompt

Task `foreman-l3kd` requests: "Implement genserver to act as a communication server for inter agent communications. As a reference use https://github.com/nicobailon/pi-intercom/tree/8b189e8668a3335c92f7fbd8531363502e924a9b, implement our own server in elixir instead of using this package."

### Reference behavior from pi-intercom

The referenced system provides:

- Local broker that tracks connected Pi sessions.
- Direct 1:1 targeted messages by name/session id/short id.
- `send`, `ask`, `reply`, `pending`, `list`, `list-cwd`, and `status` actions.
- Blocking `ask` with timeout and correlated reply.
- Inline incoming message injection with reply hints.
- Attachments for snippets/files/context.
- Bounded mailbox behavior for temporarily disconnected named sessions.
- Delivery/ack/injection state tracking.

### Foreman codebase context

Foreman is an Elixir/Phoenix OTP runtime under `packages/foreman_server`. Relevant existing patterns:

- `ForemanServer.Application` supervises long-lived GenServers and registries.
- `ForemanServer.Aggregator` + aggregate modules implement event-sourced command handling.
- `ForemanServer.AgentRuntime` owns backend adapter execution.
- Existing inbox modules (`ForemanServer.Inbox.SharedInbox`, `Poller`, `DedupeTable`, `Aggregates.InboxThread`) already model ingestion, dedupe, message append, and delivery update concepts.
- `CLAUDE.md` requires public mutation through stable façades, one-way error contracts, typed structs for aggregate state, telemetry whitelists, and no behavior drift without docs.

## 3. Problem Space

- **Problem:** Foreman agents currently lack a native, supervised channel for direct inter-agent questions, progress updates, and task handoffs.
- **Pain owner:** Foreman operator and agent workflows coordinating multiple local or supervised agents [NEEDS CLARIFICATION: Who is the primary human/operator persona for v1?].
- **Primary users:** agent processes and the Foreman runtime; possible CLI/TUI clients are not confirmed [NEEDS CLARIFICATION: Should a human-facing CLI/API be part of v1 or only an internal Elixir API?].
- **Success:** reliable agent-to-agent message delivery and correlated replies [NEEDS CLARIFICATION: What success metrics are required: delivery latency, ask timeout rate, message loss rate, or test coverage threshold?].
- **Constraints:** must be Elixir/OTP, in repo, not the external package. Other constraints are unknown [NEEDS CLARIFICATION: Must this support only one host, multiple OS users, multiple Foreman nodes, or distributed Erlang clusters?].
- **Prior solution:** pi-intercom is the reference; it is insufficient because the request forbids using the package directly and needs an Elixir-native Foreman implementation.

## 4. Requirements

### 4a. Communication Service Core

### REQ-001: Must | High | Supervised communication server
Foreman MUST provide an OTP-supervised inter-agent communication server that owns session presence, routing, message correlation, and delivery state. [RISK: incorrectly placing mutable state outside a supervised process will make delivery behavior non-deterministic.]

- AC-001-1: Given the Foreman application starts with inter-agent communication enabled, when supervision starts, then the communication server is started under `ForemanServer.Application` or a dedicated child supervisor.
- AC-001-2: Given the communication server crashes, when the supervisor restarts it, then session and mailbox recovery behavior follows the configured durability model [NEEDS CLARIFICATION: Should sessions/messages survive server crash through EventStore persistence or is in-memory restart loss acceptable for v1?].

### REQ-002: Must | High | Stable public façade
Foreman MUST expose a stable Elixir façade for communication operations instead of requiring callers to use raw `GenServer.call` directly.

- AC-002-1: Given a caller needs to register, send, ask, reply, list, or inspect pending asks, when it uses the façade, then the façade validates input and delegates to the server.
- AC-002-2: Given external modules outside the communication subsystem need messaging, when they call the service, then they do not directly call the GenServer process name.

### REQ-003: Must | High | Session registration and presence
The server MUST allow agent/session registration with enough metadata to support discovery and targeting.

- AC-003-1: Given an agent process registers, when it supplies id, optional name, cwd/project, and status metadata, then it appears in session discovery results.
- AC-003-2: Given two sessions share a name or alias, when targeting by non-unique name, then the server returns an ambiguity error rather than choosing silently.
- AC-003-3: Given a session exits or unregisters, when presence is refreshed, then the session is marked disconnected or removed according to the retention policy [NEEDS CLARIFICATION: Should disconnected sessions remain targetable through a mailbox, and for how long?].

### REQ-004: Must | High | Target resolution
The server MUST resolve recipients by exact session id, short id prefix, runtime alias, or configured name.

- AC-004-1: Given exactly one active session matches a target, when a message is sent, then delivery is routed to that session.
- AC-004-2: Given zero sessions match a target, when a message is sent, then the caller receives `{:error, :not_found}` or equivalent documented error.
- AC-004-3: Given multiple sessions match a target, when a message is sent, then the caller receives `{:error, :ambiguous_target, matches}` or equivalent documented error.

### REQ-005: Must | High | Fire-and-forget send
The server MUST support one-way `send` messages for progress updates, context sharing, and non-blocking coordination.

- AC-005-1: Given a sender, target, and message body, when `send` succeeds, then the server records/enqueues the message and returns delivery state to the sender.
- AC-005-2: Given a recipient is online, when a `send` message is delivered, then the recipient process can receive or poll the message without blocking the sender.

### REQ-006: Must | High | Blocking ask/reply workflow
The server MUST support request/reply conversations where the sender can wait for a correlated answer.

- AC-006-1: Given a sender calls `ask`, when the recipient replies before timeout, then the sender receives the reply correlated to the original message id.
- AC-006-2: Given a sender calls `ask`, when no reply arrives before timeout, then the sender receives a timeout result that includes the ask id and last known delivery state.
- AC-006-3: Given a recipient has exactly one pending ask, when it calls `reply` without an explicit ask id, then the server replies to that pending ask.
- AC-006-4: Given a recipient has multiple pending asks, when it calls `reply` without disambiguation, then the server returns an ambiguity error.

### REQ-007: Must | Medium | Pending ask inspection
The server MUST expose pending inbound asks so agents can recover from interrupted or delayed reply flows.

- AC-007-1: Given a recipient has unresolved asks, when it calls `pending`, then the server returns ask ids, senders, timestamps, and message previews.
- AC-007-2: Given an ask is answered or cancelled, when `pending` is called, then that ask is no longer listed as unresolved.

### REQ-008: Should | Medium | Bounded disconnected mailbox
The server SHOULD provide bounded mailbox behavior for temporarily disconnected named sessions. [RISK: unlimited mailbox retention can leak memory or stale sensitive context.]

- AC-008-1: Given a target is temporarily disconnected but has a retained mailbox, when a message is sent, then the message is queued with bounded retention.
- AC-008-2: Given the target reconnects before retention expiry, when mailbox delivery runs, then queued messages are delivered at most once.
- AC-008-3: Given retention expires or capacity is exceeded, when new messages arrive, then the oldest or expired messages are dropped according to documented policy [NEEDS CLARIFICATION: What default mailbox size and TTL should v1 use?].

### 4b. Payloads and Delivery Semantics

### REQ-009: Must | Medium | Message schema and attachments
Messages MUST have a documented schema with ids, sender, recipient, body, timestamps, thread/reply metadata, and optional attachments.

- AC-009-1: Given a message is accepted, when it is stored or delivered, then it has a globally unique message id and stable sender/recipient identifiers.
- AC-009-2: Given attachments are included, when the message is accepted, then each attachment has type, name, content/reference, and optional language metadata.
- AC-009-3: Given an attachment exceeds limits, when the sender submits it, then the server rejects the message with a validation error [NEEDS CLARIFICATION: What max message body and attachment sizes are allowed?].

### REQ-010: Must | High | Delivery state tracking
The server MUST track message lifecycle states sufficient for senders and operators to diagnose routing outcomes.

- AC-010-1: Given a message is accepted, delivered, acknowledged, injected/consumed, replied, timed out, cancelled, or dropped, when state changes, then the new state is recorded.
- AC-010-2: Given a sender asks for status, when the message id exists, then the server returns the latest state and relevant timestamps.
- AC-010-3: Given delivery fails, when status is requested, then the failure reason is visible without exposing recipient-private data.

### REQ-011: Should | Medium | Subscription or callback delivery
The server SHOULD support recipient-side delivery through a callback, subscription, or polling API compatible with Foreman worker processes.

- AC-011-1: Given a recipient registers a delivery handler, when a message arrives, then the handler receives the message once.
- AC-011-2: Given no handler is registered, when a message arrives, then the message remains available through polling or pending-state APIs [NEEDS CLARIFICATION: Should delivery be push-only, poll-only, or both in v1?].

### REQ-012: Must | High | Local trust and authorization boundaries
The server MUST prevent unintended cross-project or cross-session messaging. [RISK: inter-agent messages may include secrets, code snippets, or operational context.]

- AC-012-1: Given a caller tries to message a session outside its allowed scope, when authorization is enforced, then the server rejects the request.
- AC-012-2: Given a caller lists sessions, when scope filters apply, then only authorized sessions are returned.
- AC-012-3: Given messages include attachments or context snippets, when telemetry/logging occurs, then payload bodies are not logged by default.
- AC-012-4: Given v1 scope is local-only, when a remote caller attempts access, then access is denied [NEEDS CLARIFICATION: What is the exact trust scope: same BEAM node, same OS user, same project, same cwd, or authenticated HTTP clients?].

### 4c. Foreman Integration

### REQ-013: Should | Medium | Reuse existing inbox/event patterns
The implementation SHOULD reuse Foreman's existing inbox, aggregate, projection, and telemetry conventions where they fit.

- AC-013-1: Given message lifecycle events need durable auditability, when implemented, then they use existing EventStore/aggregate patterns or document why in-memory state is sufficient.
- AC-013-2: Given existing `InboxThread` or `SharedInbox` concepts overlap, when implementing, then the design avoids duplicate incompatible schemas.
- AC-013-3: Given new aggregate state is added, when events are applied, then closed top-level state uses structs as required by `CLAUDE.md`.

### REQ-014: Should | Medium | Operator/debug visibility
The communication server SHOULD expose minimal diagnostics for active sessions, pending asks, mailbox depth, and recent delivery errors.

- AC-014-1: Given an operator inspects server status, when diagnostics are requested, then the response includes counts for sessions, pending asks, queued messages, and dropped messages.
- AC-014-2: Given sensitive message bodies exist, when diagnostics are shown, then only metadata/previews are shown unless explicitly authorized [NEEDS CLARIFICATION: Should diagnostics be CLI-only, Phoenix debug route, LiveView, or internal test helper?].

### REQ-015: Could | Low | UI/CLI compatibility shim
Foreman COULD expose a thin CLI or API surface that resembles pi-intercom actions for easier migration and testing.

- AC-015-1: Given a caller invokes `list`, `list-cwd`, `send`, `ask`, `reply`, `pending`, or `status`, when the shim is enabled, then it maps to the Elixir façade without depending on the external package.
- AC-015-2: Given the shim is out of scope for v1 implementation, when the core server is complete, then all core behavior remains testable via the Elixir façade.

## 5. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | none | Root service lifecycle |
| REQ-002 | REQ-001 | Public API over server |
| REQ-003 | REQ-001, REQ-002 | Presence before routing |
| REQ-004 | REQ-003 | Targeting requires registry |
| REQ-005 | REQ-004, REQ-009, REQ-010 | Basic send |
| REQ-006 | REQ-005, REQ-007, REQ-010 | Ask/reply correlation |
| REQ-007 | REQ-006 | Pending ask recovery |
| REQ-008 | REQ-003, REQ-005, REQ-010 | Disconnected delivery |
| REQ-009 | REQ-005 | Message contract |
| REQ-010 | REQ-005, REQ-006 | State tracking |
| REQ-011 | REQ-005 | Recipient consumption |
| REQ-012 | REQ-003, REQ-004, REQ-009 | Security boundary |
| REQ-013 | REQ-001, REQ-009, REQ-010 | Foreman architecture fit |
| REQ-014 | REQ-010 | Diagnostics from state |
| REQ-015 | REQ-002 | Optional compatibility layer |

No circular dependencies identified. REQ-001 through REQ-007 form the minimum viable cluster.

## 6. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Supervised communication server | Must | High | 2 |
| REQ-002 | Stable public façade | Must | High | 2 |
| REQ-003 | Session registration and presence | Must | High | 3 |
| REQ-004 | Target resolution | Must | High | 3 |
| REQ-005 | Fire-and-forget send | Must | High | 2 |
| REQ-006 | Blocking ask/reply workflow | Must | High | 4 |
| REQ-007 | Pending ask inspection | Must | Medium | 2 |
| REQ-008 | Bounded disconnected mailbox | Should | Medium | 3 |
| REQ-009 | Message schema and attachments | Must | Medium | 3 |
| REQ-010 | Delivery state tracking | Must | High | 3 |
| REQ-011 | Subscription or callback delivery | Should | Medium | 2 |
| REQ-012 | Local trust and authorization boundaries | Must | High | 4 |
| REQ-013 | Reuse existing inbox/event patterns | Should | Medium | 3 |
| REQ-014 | Operator/debug visibility | Should | Medium | 2 |
| REQ-015 | UI/CLI compatibility shim | Could | Low | 2 |

## 7. Risks and Open Questions

### Risks

1. **Scope creep from pi-intercom parity:** Full package parity includes UI overlays and Pi extension behavior that may not belong in Foreman. Mitigation: v1 minimum cluster is REQ-001 through REQ-007 plus REQ-009/010/012.
2. **Durability ambiguity:** Ask/reply behavior differs substantially if persisted in EventStore vs in-memory GenServer state. Mitigation: mark durability as clarification and require TRD to choose explicitly.
3. **Security leakage:** Message bodies may contain source code, secrets, or task context. Mitigation: no payload logging by default; authorization scope must be explicit.
4. **Existing inbox overlap:** Foreman already has inbox concepts. Mitigation: TRD must map reuse vs new modules before coding.
5. **Blocking ask implementation:** Blocking calls can deadlock if implemented as unbounded GenServer calls. Mitigation: TRD should use monitored waiters, explicit timeouts, and non-blocking server state.

### Open Questions

All open questions are represented inline as `[NEEDS CLARIFICATION: ...]` markers. They should be resolved by `/ensemble:refine-prd` before implementation TRD work if the team needs Ready status.

## 8. Self-Critique and Applied Resolutions

1. **Issue:** Original task says "genserver" singular, but requirements need façade, presence registry, mailbox, and waiters. **Applied resolution:** PRD requires an OTP-supervised service while leaving exact process split to TRD.
2. **Issue:** Reference package includes Pi UI/tooling behavior outside Foreman. **Applied resolution:** PRD treats pi-intercom as behavior reference, not parity mandate; UI/CLI shim is Could.
3. **Issue:** Durability is unresolved. **Applied resolution:** marked crash/mailbox persistence as clarification and made delivery-state tracking explicit.
4. **Issue:** Security scope is missing. **Applied resolution:** added REQ-012 as Must with explicit no-payload-logging ACs.
5. **Issue:** Existing Foreman inbox modules may duplicate the new feature. **Applied resolution:** added REQ-013 requiring reuse or documented separation.

## 9. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Core feature areas covered: presence, targeting, send, ask/reply, pending, mailbox, schema, delivery, security, diagnostics. |
| Testability | 4 | All requirements have ACs; many can map to ExUnit GenServer/facade tests. |
| Clarity | 3 | Multiple scope/durability/security choices remain open. |
| Feasibility | 3 | Feasible in OTP, but persistence and integration boundaries affect complexity. |
| Overall | 3.5 | CONCERNS — save as Draft per Foreman mode. |

## 10. Notes

- Foreman mode was used. No live interview, SCAMPER, user confirmation, or readiness-gate halt was run.
- Inferred scale depth: STANDARD. Reasoning: the prompt names one primary feature, one explicit tech constraint (Elixir GenServer), one external reference, and an architectural integration point (inter-agent communication), but lacks enterprise/multi-team or compliance details.
- Creative elicitation was skipped because no human follow-up is available in Foreman mode.
- Codebase reconnaissance found an Elixir/Phoenix runtime in `packages/foreman_server`, existing OTP supervision in `ForemanServer.Application`, agent runtime conventions in `CLAUDE.md`, and inbox-related modules that may be reused.
- Ambiguity scan complete: 13 items marked for clarification.

## 11. Suggested Next Step

Run `/ensemble:refine-prd /Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b09923de-create-a-prd-trd-for-intercomm-style-inter-agent.md` to resolve the 13 open clarification markers before generating a TRD.
