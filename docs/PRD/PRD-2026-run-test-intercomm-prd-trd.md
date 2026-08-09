---
document_id: PRD-2026-run-test
label: prd-intercomm-prd-trd
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 10
readiness_score: 3.8
---

# PRD: InterComm — Inter-Agent Communication Server

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 7 |
| Should | 2 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| AC coverage | 10/10 (100%) — 27 ACs total |
| Risk flags | 4 |
| Dependencies | 5 |
| Open ambiguity markers | 0 |
| Resolved ambiguity markers | 8/8 |

---

## 1. Executive Summary

**What this PRD defines:** a supervised Elixir `GenServer` that acts as Foreman's local inter-agent communication hub. It gives workers/agents a canonical way to send messages, ask blocking questions, reply, inspect pending inbox items, and correlate communication with a run/phase/worker context.

**Why it exists:** Foreman has worker lifecycle events, assistant-message events, and an `InboxThread` aggregate shape, but no live communication server that agents can use to coordinate with each other. Current coordination is ad hoc: stdout/stderr, phase artifacts, or external operator channels. InterComm makes agent-to-agent communication explicit, traceable, testable, and bounded.

---

## 2. Background and Evidence

Observed in the repository:

- `ForemanServer.Overwatch.WorkerProtocol.emit/2` is the production worker boundary for lifecycle events: heartbeat, worker start/exit, tool calls, assistant messages, stdout, stderr.
- `ForemanServer.Aggregates.InboxThread` already defines command handling for `inbox.send` and `inbox.delivery.update`, emitting `InboxMessageAppended` and `InboxDeliveryUpdated` into stream `inbox:<run_id>`.
- `ForemanServer.Inbox.SharedInbox` normalizes external ingestion and dedupes events, but it is source-ingress oriented, not live agent-to-agent routing.
- `ForemanServer.CommandRouter` broadcasts debug state via `Phoenix.PubSub`, and debug LiveViews already subscribe to run/phase/worker topics.
- No `InterComm`, `Intercom`, `Conversation`, or agent mailbox server exists under `packages/foreman_server/lib`.

Consequence: v1 should be a small OTP subsystem that reuses Foreman's event-store/command-router shape for audit while owning fast in-memory delivery state in a GenServer.

---

## 3. Personas

### 3.1 Worker agent

- Needs to send a structured message to another worker or role.
- Needs to ask a question and wait for a reply without parsing logs.
- Needs bounded, deterministic timeout behavior.

### 3.2 Coordinator agent

- Needs to fan out subtasks, wait for replies, and inspect unresolved asks.
- Needs clear correlation IDs across run, phase, worker, and task.

### 3.3 Operator / debugger

- Needs to inspect message history and pending asks for a run.
- Needs an event/audit trail when a coordination failure blocks a run.

---

## 4. Requirements

### REQ-001: Must | High | InterComm public API

Foreman MUST expose a module `ForemanServer.InterComm` as the only supported caller-facing API for inter-agent communication.

- AC-001-1: Given a caller invokes `InterComm.send_message/2`, when required routing fields are valid, then the call returns `{:ok, message}` with a stable `message_id`.
- AC-001-2: Given a caller invokes `InterComm.ask/2`, when the message is accepted, then the call returns `{:ok, ask}` containing `ask_id`, `message_id`, and timeout metadata.
- AC-001-3: Given a caller invokes `InterComm.reply/2`, when the target ask is pending, then the original asker is notified and the ask state becomes replied.
- AC-001-4: Given a caller uses any InterComm API with malformed payload, then the API returns `{:error, validation_error}` and does not mutate server state.

### REQ-002: Must | High | Supervised GenServer hub

Foreman MUST implement a supervised GenServer (`ForemanServer.InterComm.Server`) that owns live mailboxes, pending asks, waiter registrations, and delivery state.

- AC-002-1: Given the Foreman application starts, when supervision tree initialization completes, then `InterComm.Server` is running under a named supervisor child.
- AC-002-2: Given the server receives a message, when the recipient mailbox does not yet exist, then the mailbox is created lazily.
- AC-002-3: Given the server crashes and restarts, when callers query live pending state, then volatile waiters are gone and persisted/audited message history remains available through the event/projection path.

### REQ-003: Must | High | Addressing model

InterComm MUST support scoped addressing by run, phase, worker, role, and broadcast topic.

- AC-003-1: Given a message is addressed to `worker:<worker_id>` within a `run_id`, then only that worker mailbox receives it.
- AC-003-2: Given a message is addressed to `role:<role>` within a `run_id`, then all registered live recipients for that role receive it.
- AC-003-3: Given a message is addressed to `run:<run_id>`, then it is visible in the run-level mailbox and on the run PubSub topic.
- AC-003-4: Given a message references `phase_id` or `task_id`, then those fields are retained as correlation metadata and not used as implicit routing unless explicitly addressed.

### REQ-004: Must | High | Ask/reply semantics

InterComm MUST support request/reply flows with explicit ask IDs, one terminal reply, and configurable timeouts.

- AC-004-1: Given an ask is created, when no reply arrives before the configured timeout, then the waiter receives `{:error, :timeout}` and the ask state becomes timed_out.
- AC-004-2: Given an ask is replied to once, when a second reply is attempted, then the second reply returns `{:error, :already_replied}`.
- AC-004-3: Given an asker process exits before reply, when a reply later arrives, then the ask is marked orphaned and retained for audit instead of crashing the server.

### REQ-005: Must | High | Delivery state and pending queries

InterComm MUST expose query functions for pending asks and mailbox messages.

- AC-005-1: Given a worker has pending inbox items, when `InterComm.pending/1` is called for that worker, then the result includes messages and asks sorted by insertion sequence.
- AC-005-2: Given a coordinator asks for `InterComm.pending(run_id: run_id)`, then all unresolved asks for that run are returned without cross-run leakage.
- AC-005-3: Given a message is acknowledged, when pending is queried again, then acknowledged non-ask messages are omitted by default but can be included with `include_acknowledged: true`.

### REQ-006: Must | Medium | Event/audit integration

InterComm MUST write accepted messages and delivery transitions through Foreman's command/event path rather than storing audit history only in process memory.

- AC-006-1: Given a message is accepted, when audit is enabled, then an `inbox.send` command is dispatched for stream `inbox:<run_id>` with `message_id`, `body`, sender, recipient, and correlation metadata.
- AC-006-2: Given delivery state changes to acknowledged, replied, timed_out, or orphaned, then an `inbox.delivery.update` command is dispatched with the same `message_id` and a closed delivery-status value.
- AC-006-3: Given command dispatch fails, then the live delivery state is not marked delivered; the API returns `{:error, {:audit_failed, reason}}` unless `audit?: false` is explicitly supplied in test-only options.

### REQ-007: Must | Medium | PubSub notifications

InterComm MUST publish delivery notifications via Phoenix.PubSub for UI/debug and live worker subscription.

- AC-007-1: Given a message is accepted for a run, then `Phoenix.PubSub.broadcast(ForemanServer.PubSub, "intercomm:runs:<run_id>", event)` is called.
- AC-007-2: Given a message is addressed to a worker, then a worker-specific topic receives the same event.
- AC-007-3: Given PubSub is unavailable in a minimal test process, then the API still succeeds and records a telemetry warning instead of crashing.

### REQ-008: Should | Medium | Worker protocol bridge

Foreman SHOULD provide a worker-safe bridge so launched worker runtimes can use InterComm without depending on internal GenServer calls.

- AC-008-1: Given a worker runtime receives an InterComm command envelope, when it calls the bridge, then the bridge validates `worker_id` and `run_id` against its launch context.
- AC-008-2: Given a worker tries to send as another worker, then the bridge rejects the call with `{:error, :sender_mismatch}`.
- AC-008-3: Given the bridge emits assistant-readable output, then it does not expose private process identifiers or internal mailbox state.

### REQ-009: Should | Medium | Telemetry and debug visibility

InterComm SHOULD emit telemetry and expose debug views for message traffic.

- AC-009-1: Given a message is accepted, replied, timed out, or acknowledged, then a `[:foreman_server, :intercomm, :message]` telemetry event is emitted with run_id, status, recipient_type, latency_ms, and mailbox depth.
- AC-009-2: Given an operator opens the debug dashboard, then run/worker debug state can include pending InterComm counts without loading full message bodies by default.

### REQ-010: Could | Low | Capacity limits and pruning

InterComm COULD enforce per-run and per-mailbox limits to prevent unbounded in-memory growth.

- AC-010-1: Given a mailbox exceeds configured `max_messages`, then oldest acknowledged messages are pruned before accepting new non-acknowledged messages.
- AC-010-2: Given pending asks exceed configured `max_pending_asks`, then new asks return `{:error, :mailbox_full}`.

---

## 5. Ambiguity Resolution Status

| # | Item | Resolution |
|---:|---|---|
| 1 | Is InterComm durable or in-memory? | Hybrid: GenServer owns live state; accepted messages/delivery transitions are audited via existing inbox command/event path. |
| 2 | Should asks block the GenServer? | No. Waiters are tracked by monitor/ref; GenServer never blocks on recipient behavior. |
| 3 | Can one ask have multiple replies? | No. v1 permits one terminal reply. Fan-in uses multiple asks. |
| 4 | Are recipients processes, workers, or roles? | Addressing is logical. Optional live process registrations map logical addresses to notification targets. |
| 5 | What is timeout default? | 5 minutes default, configurable globally and per ask. |
| 6 | Does InterComm replace `InboxThread`? | No. It uses `InboxThread` for audit and adds live delivery/query behavior. |
| 7 | Are message bodies persisted? | Yes when audit is enabled. Sensitive data redaction is caller-owned in v1. |
| 8 | Is cross-run communication allowed? | No by default. Every message has one required `run_id`; cross-run send returns validation error. |

---

## 6. Dependency Map

- REQ-001 depends on REQ-002.
- REQ-004 depends on REQ-001, REQ-002, and REQ-005.
- REQ-006 depends on existing `InboxThread`, `CommandRouter`, and event-store behavior.
- REQ-007 depends on existing `ForemanServer.PubSub`.
- REQ-008 depends on existing `Overwatch.WorkerProtocol` launch context.

---

## 7. Risks and Non-Goals

### Risks

1. **Mailbox growth:** unbounded mailboxes can create memory pressure. Mitigation: REQ-010 limits/pruning.
2. **Audit/live mismatch:** command dispatch failures can leave live state ahead of event history. Mitigation: accepted messages require audit success by default.
3. **Dead askers:** requester processes may exit before reply. Mitigation: monitor waiters and mark orphaned.
4. **Sensitive data:** message body persistence can leak secrets. Mitigation: v1 documents caller-owned redaction; future work may add server-side redaction policy.

### Non-goals for v1

- Distributed Erlang or multi-node delivery.
- External chat integrations.
- Multi-reply streaming conversations.
- End-user UI composition beyond debug visibility.
- Cryptographic message encryption.

---

## 8. Acceptance Criteria Summary

| REQ | Description | Priority | AC Count |
|---|---|---|---:|
| REQ-001 | Public API | Must | 4 |
| REQ-002 | Supervised GenServer hub | Must | 3 |
| REQ-003 | Addressing model | Must | 4 |
| REQ-004 | Ask/reply semantics | Must | 3 |
| REQ-005 | Pending queries | Must | 3 |
| REQ-006 | Event/audit integration | Must | 3 |
| REQ-007 | PubSub notifications | Must | 3 |
| REQ-008 | Worker bridge | Should | 3 |
| REQ-009 | Telemetry/debug | Should | 2 |
| REQ-010 | Capacity limits | Could | 2 |

---

## 9. Readiness Gate

Draft readiness score: **3.8 / 5.0**.

- Requirements are implementable and mapped to existing Foreman subsystems.
- Main implementation uncertainties are command-router authorization for `inbox.*` system commands and exact worker bridge surface.
- TRD may proceed with explicit verification tasks for those uncertainties.
