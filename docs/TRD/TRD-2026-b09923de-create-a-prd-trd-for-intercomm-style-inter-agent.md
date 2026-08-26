---
document_id: TRD-2026-b09923de
label: trd-create-a-prd-trd-for-intercomm-style-inter-agent
prd: docs/PRD/PRD-2026-b09923de-create-a-prd-trd-for-intercomm-style-inter-agent.md
version: 1.0.0
status: Draft
date: 2026-08-10
design_readiness_score: 3.8
kind: trd
---

# TRD: Elixir Inter-Agent Communication Server

## Document Purpose

This document defines the technical design and implementation plan for a native Foreman inter-agent communication server. It converts `PRD-2026-b09923de` into OTP architecture, public API contracts, state models, tests, and independently reviewable PR slices.

The scope is an in-repo Elixir implementation inspired by `pi-intercom` behavior, not a dependency on the external package. The primary v1 consumer is Foreman/Pi worker coordination through an Elixir façade. Human-facing CLI/API compatibility remains optional and isolated from the core service.

## PRD Validation Summary

| Check | Result |
|---|---|
| Source document | `docs/PRD/PRD-2026-b09923de-create-a-prd-trd-for-intercomm-style-inter-agent.md` |
| PRD status | Draft |
| Readiness gate | 3.5 — CONCERNS, skipped as blocker because `--foreman` mode requires unattended Draft output |
| Requirement sequence | `REQ-001` through `REQ-015`, sequential |
| Acceptance criteria | 39, all associated with an existing requirement |
| Must requirement coverage | Every Must requirement has implementation and test coverage in this TRD |
| Ambiguities | 13 open PRD clarification markers carried into design notes |
| Constraints | Elixir/OTP, in-repo, no external `pi-intercom` dependency, stable façade over raw GenServer calls |

The PRD uses Executive Summary/Background sections as the product context, requirement-local Given/When/Then entries as acceptance criteria, and a dependency map for sequencing.

## Reused Capabilities

The capability registry returned no foundational TRD capabilities, and overlap analysis reported no overlapping target files across current TRDs. This TRD has no cross-TRD foundational dependency.

Commands used:

```text
node ../ensemble/packages/development/lib/trd-graph-cli.js capabilities docs/TRD --json
# {"capabilities": []}

node ../ensemble/packages/development/lib/trd-graph-cli.js overlap docs/TRD
# No overlapping target files across TRDs.
```

Existing code-level facilities reused:

| Existing facility | Reuse |
|---|---|
| `ForemanServer.Application` | Starts the communication server and optional registry/cleanup children |
| `ForemanServer.Telemetry` | Emits privacy-safe communication metrics without payload bodies |
| `ForemanServer.Aggregates.InboxThread` | Reused or extended for durable message append and delivery updates when EventStore persistence is enabled |
| `ForemanServer.Inbox.SharedInbox` / `DedupeTable` | Reference for bounded ingestion/dedupe behavior; not reused for direct agent messaging unless schemas align |
| `ForemanServer.AgentRuntime` and worker protocol tests | Integration point for Pi worker session registration and delivery handler tests |
| ExUnit + supervised test helpers | Deterministic GenServer, timeout, telemetry, and application-child tests |

## Architecture Decision

### Selected: Option B — Supervised Communication Subsystem with Durable Event Hooks

Implement a dedicated communication subsystem:

- `ForemanServer.Comms` public façade.
- `ForemanServer.Comms.Server` GenServer owning presence, target resolution, pending asks, mailbox queues, waiters, and status snapshots.
- Typed structs under `ForemanServer.Comms.*` for sessions, messages, attachments, delivery states, ask waiters, and diagnostics.
- Optional `ForemanServer.Comms.EventSink` that writes message lifecycle events through existing aggregate/EventStore paths when durability is enabled.
- Privacy-safe telemetry helpers in `ForemanServer.Telemetry`.
- ExUnit coverage for façade contracts, server state transitions, ask/reply timeouts, disconnected mailboxes, auth scopes, and telemetry redaction.

This option is selected because the PRD needs crash behavior, ask/reply coordination, bounded mailbox policy, and diagnostics. A single GenServer remains the authoritative runtime coordinator for v1, but all callers use a stable façade and pure validation/resolution helpers so the implementation can later split into registries/supervisors without changing public API.

`--foreman` note: Option B was auto-selected for Draft output. A human refine pass can downgrade to Option A if v1 only needs in-memory direct messaging, or upgrade to distributed/persistent architecture if multi-node support is required.

### Alternatives Considered

#### Option A — Minimal In-Memory GenServer

A single `ForemanServer.Comms.Server` stores all sessions, messages, asks, and queues in memory. The façade validates inputs and delegates to `GenServer.call/cast`.

- **Pros:** fastest delivery; smallest file set; easy ExUnit isolation.
- **Cons:** crash loses sessions/messages; weaker auditability; harder to diagnose delivery history; less aligned with EventStore-first conventions.
- **Complexity impact:** low initial, medium migration cost.
- **Risk profile:** acceptable for experiments only; rejected as default because PRD flags durability and delivery-state diagnosis.

#### Option B — Supervised Communication Subsystem with Durable Event Hooks (selected)

A façade and coordinator GenServer own runtime behavior, while typed structs and an event sink preserve boundaries and allow durability by configuration.

- **Pros:** good OTP fit; bounded blocking; compatible with Foreman's EventStore conventions; testable without full persistence; future split possible.
- **Cons:** more modules; requires clear event/payload redaction rules; persistence scope must be decided.
- **Complexity impact:** medium.
- **Risk profile:** best match for Must requirements and open durability concerns.

#### Option C — Reuse Existing InboxThread as Primary API

Expose direct messaging entirely through existing `InboxThread` aggregate commands and projections.

- **Pros:** maximizes existing event-sourced concepts; durable by default.
- **Cons:** current `InboxThread` is run-scoped and too small for session presence, blocking ask waiters, mailbox TTL, delivery handlers, and target resolution; would overload an existing concept.
- **Complexity impact:** medium-high schema migration.
- **Risk profile:** rejected for v1 core; selected design may reuse/extend it only for durable lifecycle event recording.

## System Architecture

### Component Boundaries

| Component | Responsibility | Target files |
|---|---|---|
| `ForemanServer.Comms` | Public façade for `start_link`, `register`, `unregister`, `list`, `list_cwd`, `send_message`, `ask`, `reply`, `pending`, `status`, `diagnostics` | `packages/foreman_server/lib/foreman_server/comms.ex` |
| `ForemanServer.Comms.Server` | GenServer state machine for sessions, target resolution, message lifecycle, waiters, mailboxes, diagnostics | `packages/foreman_server/lib/foreman_server/comms/server.ex` |
| `ForemanServer.Comms.Session` | Typed session metadata, aliases, scope, delivery handler, connected/disconnected state | `packages/foreman_server/lib/foreman_server/comms/session.ex` |
| `ForemanServer.Comms.Message` | Message schema: id, kind, sender, recipient, body, timestamps, attachments, thread/reply ids | `packages/foreman_server/lib/foreman_server/comms/message.ex` |
| `ForemanServer.Comms.Attachment` | Attachment validation, limits, preview/sanitization | `packages/foreman_server/lib/foreman_server/comms/attachment.ex` |
| `ForemanServer.Comms.Delivery` | Closed delivery-state vocabulary and transition helpers | `packages/foreman_server/lib/foreman_server/comms/delivery.ex` |
| `ForemanServer.Comms.AuthScope` | Same-project/cwd authorization and list visibility checks | `packages/foreman_server/lib/foreman_server/comms/auth_scope.ex` |
| `ForemanServer.Comms.EventSink` | Optional lifecycle event append and EventStore/inbox integration adapter | `packages/foreman_server/lib/foreman_server/comms/event_sink.ex` |
| `ForemanServer.Telemetry` | Adds `[:foreman, :comms, ...]` events with redacted metadata | `packages/foreman_server/lib/foreman_server/telemetry.ex` |
| `ForemanServer.Application` | Starts comms server when enabled; config defaults | `packages/foreman_server/lib/foreman_server/application.ex` |
| Tests | Unit/integration coverage | `packages/foreman_server/test/foreman_server/comms/**/*_test.exs` |

### Data Model

#### Session

```elixir
%ForemanServer.Comms.Session{
  id: "session-uuid",
  short_id: "session",
  name: "planner" | nil,
  aliases: ["planner"],
  cwd: "/repo",
  project_id: "foreman",
  owner: self(),
  delivery: {:pid, pid()} | {:mfa, module, function, args} | :poll,
  status: :connected | :disconnected,
  registered_at_ms: integer(),
  last_seen_ms: integer(),
  scope: %{project_id: binary(), cwd: binary(), os_user: binary() | nil}
}
```

#### Message

```elixir
%ForemanServer.Comms.Message{
  id: "msg-uuid",
  kind: :send | :ask | :reply,
  sender_id: binary(),
  recipient_id: binary(),
  body: binary(),
  attachments: [%ForemanServer.Comms.Attachment{}],
  thread_id: binary() | nil,
  reply_to_id: binary() | nil,
  ask_id: binary() | nil,
  created_at_ms: integer(),
  expires_at_ms: integer() | nil,
  delivery_state: :accepted | :queued | :delivered | :acknowledged | :consumed | :replied | :timed_out | :cancelled | :dropped | :failed,
  failure_reason: term() | nil
}
```

#### Server State

```elixir
%{
  sessions_by_id: %{session_id => %Session{}},
  targets: %{normalized_target => MapSet.t(session_id)},
  pending_by_recipient: %{recipient_id => [ask_id]},
  asks: %{ask_id => %{message_id: id, sender_id: id, recipient_id: id, from: GenServer.from(), timeout_ref: ref}},
  mailboxes: %{session_key => :queue.queue(message_id)},
  messages: %{message_id => %Message{}},
  config: %{mailbox_ttl_ms: 300_000, mailbox_max_messages: 100, ask_timeout_ms: 60_000, max_body_bytes: 65_536, max_attachment_bytes: 262_144},
  counters: %{dropped: non_neg_integer(), failed: non_neg_integer()}
}
```

### Data Flow

1. Caller invokes `ForemanServer.Comms.register/1` with identity/scope metadata.
2. Façade validates required fields and calls `Comms.Server`.
3. Server monitors registered owner pids, indexes exact id, short id prefix, name, aliases, cwd/project, and stores delivery handler.
4. Caller invokes `send_message/3` or `ask/3`.
5. Façade validates body/attachments, applies auth-scope request metadata, and delegates.
6. Server resolves target:
   - zero matches -> `{:error, :not_found}`;
   - multiple matches -> `{:error, {:ambiguous_target, matches}}`;
   - one match -> authorized delivery path.
7. Server creates message id, stores lifecycle state, emits telemetry, optionally appends durable event.
8. Online recipient receives message via pid/MFA callback or can poll; disconnected retained recipient queues bounded mailbox entry.
9. `ask/3` registers a waiter and timeout timer outside recipient delivery; `reply/2|3` resolves the ask id, stores reply, replies to the original caller, and clears pending state.
10. `status/1` and `diagnostics/0` return metadata-only snapshots.

### Error Contract

Public façade functions return stable tuples:

```elixir
{:ok, result}
{:error, :not_found}
{:error, {:ambiguous_target, [safe_match()]}}
{:error, :unauthorized}
{:error, {:validation, field, reason}}
{:error, {:timeout, ask_id, delivery_state}}
{:error, {:not_pending, ask_id}}
{:error, {:delivery_failed, reason}}
```

No caller outside `ForemanServer.Comms.*` should call `GenServer.call(ForemanServer.Comms.Server, ...)` directly.

### Configuration Defaults

Until the PRD clarification markers are resolved, v1 uses safe defaults:

| Setting | Default | Rationale |
|---|---:|---|
| `:comms_enabled` | `true` in test/dev, configurable in runtime | Must start under OTP when enabled |
| `:comms_mailbox_ttl_ms` | `300_000` | bounded retention without indefinite sensitive storage |
| `:comms_mailbox_max_messages` | `100` | prevents memory growth |
| `:comms_ask_timeout_ms` | `60_000` | avoids unbounded blocking |
| `:comms_max_body_bytes` | `65_536` | enough for context snippets, small enough for memory safety |
| `:comms_max_attachment_bytes` | `262_144` | supports snippets/files while preventing large payloads |
| `:comms_auth_scope` | `:same_project_or_cwd` | conservative local trust boundary |
| `:comms_durability` | `:event_sink_optional` | testable in memory, extensible to EventStore |

## Master Task List

### PR 1: Public Contracts, Supervision, and Base Server

**Shippable State:** Elixir callers can register the communication service under Foreman supervision and receive validated façade errors/status without using raw GenServer calls.

#### TRD-001 — Add comms façade and typed public contract (4h) [satisfies REQ-002]

Create `ForemanServer.Comms` with documented functions for `register/1`, `unregister/1`, `list/1`, `list_cwd/2`, `send_message/3`, `ask/3`, `reply/2`, `reply/3`, `pending/1`, `status/1`, and `diagnostics/0`.

Validates PRD ACs: AC-002-1, AC-002-2, AC-015-2

Implementation AC:

- Given a caller invokes a supported façade function with invalid input, when validation fails, then it returns a documented `{:error, ...}` tuple without touching the server.
- Given external code uses comms, when Credo/static grep checks run, then call sites outside `ForemanServer.Comms.*` do not call `ForemanServer.Comms.Server` directly.

#### TRD-001-TEST — Test façade validation and raw-call boundary (3h) [verifies TRD-001] [satisfies REQ-002]

Add ExUnit tests for façade function exports, validation errors, and direct server-call boundary enforcement.

Validates PRD ACs: AC-002-1, AC-002-2, AC-015-2

Implementation AC:

- Given invalid registration, message, and reply payloads, when tests call the façade, then each returns the expected stable error tuple.
- Given source files are scanned in an architecture test, when direct server calls exist outside allowed modules, then the test fails with file/line evidence.

#### TRD-002 — Add typed message/session/delivery structs (5h) [satisfies REQ-003, REQ-009, REQ-010]

Implement `Session`, `Message`, `Attachment`, and `Delivery` structs with constructors, field validation, size limits, state vocabulary, timestamps, and metadata previews.

Validates PRD ACs: AC-003-1, AC-009-1, AC-009-2, AC-009-3, AC-010-1

Implementation AC:

- Given valid message input, when `Message.new/1` runs, then the result includes a unique id, stable sender/recipient ids, timestamps, and initial `:accepted` state.
- Given oversize body or attachment input, when validation runs, then it returns `{:error, {:validation, field, reason}}` and never stores payload.

#### TRD-002-TEST — Test struct construction and validation (3h) [verifies TRD-002] [satisfies REQ-003, REQ-009, REQ-010]

Add unit tests for session metadata, message id generation, attachment schema, size-limit rejection, and delivery transitions.

Validates PRD ACs: AC-003-1, AC-009-1, AC-009-2, AC-009-3, AC-010-1

Implementation AC:

- Given boundary-size bodies/attachments, when constructors run, then under-limit values pass and over-limit values fail deterministically.
- Given invalid delivery state transitions, when `Delivery.transition/2` runs, then it rejects them with a stable error.

#### TRD-003 — Start server under application supervision (4h) [satisfies REQ-001]

Add `ForemanServer.Comms.Server` as a named GenServer and start it from `ForemanServer.Application` when `:comms_enabled` is true. Define restart behavior and initial state.

Validates PRD ACs: AC-001-1, AC-001-2

Implementation AC:

- Given `:comms_enabled` is true, when `ForemanServer.Application` starts, then `Process.whereis(ForemanServer.Comms.Server)` returns a live pid.
- Given the server exits, when the supervisor restarts it, then the state recovery behavior follows configured `:comms_durability` and defaults to clean in-memory state.

#### TRD-003-TEST — Test supervision and crash recovery contract (3h) [verifies TRD-003] [satisfies REQ-001]

Add application-child tests using existing test support patterns.

Validates PRD ACs: AC-001-1, AC-001-2

Implementation AC:

- Given the test application starts, when the comms feature is enabled, then the server child is supervised and registered.
- Given the server is killed in a test, when it restarts, then status returns a documented empty or recovered state instead of crashing.

### PR 2: Presence, Target Resolution, and Authorization

**Shippable State:** Registered local agents can discover authorized sessions and target exactly one recipient by id, short id, name, alias, cwd, or project, with clear not-found/ambiguous/unauthorized errors.

#### TRD-004 — Implement session registration and presence indexes (6h) [satisfies REQ-003]

Support `register/1`, `unregister/1`, process monitors, connected/disconnected state, name/alias/cwd/project indexes, and `list/1`/`list_cwd/2`.

Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3

Implementation AC:

- Given a session registers with id, name, cwd, project, and aliases, when discovery runs, then it appears with metadata-only fields.
- Given the owner pid exits, when the monitor message is handled, then the session is marked disconnected or removed according to configured retention policy.

#### TRD-004-TEST — Test registration, discovery, and monitor cleanup (4h) [verifies TRD-004] [satisfies REQ-003]

Add GenServer tests for registration, duplicate names, list filters, unregister, and owner-pid exits.

Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3

Implementation AC:

- Given two sessions share a name, when discovery/targeting by name runs, then ambiguity is visible and no silent winner is chosen.
- Given a monitored session process dies, when state is inspected, then disconnected/removal behavior matches config.

#### TRD-005 — Implement deterministic target resolution (5h) [satisfies REQ-004]

Add exact id, short-id prefix, runtime alias, name, cwd, and project target resolution with safe match summaries.

Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3

Implementation AC:

- Given exactly one target matches, when `resolve_target/2` runs, then it returns `{:ok, session}`.
- Given zero or multiple targets match, when resolution runs, then it returns `:not_found` or safe ambiguity metadata and performs no delivery.

#### TRD-005-TEST — Test target-resolution edge cases (4h) [verifies TRD-005] [satisfies REQ-004]

Add unit tests for exact id, short id prefixes, aliases, cwd/project filters, zero matches, and multi-match ambiguity.

Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3

Implementation AC:

- Given overlapping short ids, when a prefix matches more than one session, then the result is `{:error, {:ambiguous_target, matches}}`.
- Given a target does not exist, when send/ask uses it, then no message id is created.

#### TRD-006 — Enforce local authorization scopes (5h) [satisfies REQ-012]

Implement `AuthScope` checks for same project/cwd local messaging and list visibility. Reject remote/unauthorized attempts and keep payloads out of telemetry/log metadata.

Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-012-4

Implementation AC:

- Given caller scope and recipient scope differ outside policy, when messaging/listing runs, then it returns `{:error, :unauthorized}` or filters the session.
- Given message bodies and attachments exist, when authorization failure or telemetry occurs, then payload body/content does not appear in emitted metadata.

#### TRD-006-TEST — Test authorization and redaction boundaries (4h) [verifies TRD-006] [satisfies REQ-012]

Add tests for same-project allowed, cross-project denied, same-cwd allowed by config, remote scope denied, and telemetry/log redaction.

Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-012-4

Implementation AC:

- Given unauthorized recipient scope, when `send_message/3` runs, then it returns `{:error, :unauthorized}` and no message is stored.
- Given a secret-like body is sent, when telemetry is captured, then the raw body and attachment content are absent.

### PR 3: Send Delivery, Polling/Callbacks, and Status

**Shippable State:** Authorized agents can send one-way messages to online recipients, consume or poll them once, and inspect metadata-only delivery status.

#### TRD-007 — Implement fire-and-forget send and online delivery (6h) [satisfies REQ-005, REQ-010, REQ-011]

Implement `send_message/3` lifecycle: accept, resolve, authorize, store metadata, deliver to pid/MFA/poll queue, update delivery states.

Validates PRD ACs: AC-005-1, AC-005-2, AC-010-1, AC-011-1, AC-011-2

Implementation AC:

- Given an online recipient with pid delivery, when a sender sends a message, then recipient receives one safe `%Message{}` event and sender gets current delivery state.
- Given no push handler is configured, when a message arrives, then it remains retrievable through polling APIs.

#### TRD-007-TEST — Test send delivery modes (5h) [verifies TRD-007] [satisfies REQ-005, REQ-010, REQ-011]

Add tests for pid handler, MFA handler, polling mode, callback failure handling, and duplicate-consumption prevention.

Validates PRD ACs: AC-005-1, AC-005-2, AC-010-1, AC-011-1, AC-011-2

Implementation AC:

- Given a pid handler is registered, when send succeeds, then the test process receives exactly one message.
- Given handler delivery fails, when status is requested, then failure reason is visible as metadata without body content.

#### TRD-008 — Implement status and delivery-state diagnostics (4h) [satisfies REQ-010, REQ-014]

Add `status(message_id)` and `diagnostics/0` returning lifecycle state, timestamps, counts, queue depths, pending ask counts, dropped counts, and recent safe errors.

Validates PRD ACs: AC-010-2, AC-010-3, AC-014-1, AC-014-2

Implementation AC:

- Given a known message id, when status is requested, then latest state and timestamps are returned.
- Given diagnostics are requested, when messages include bodies, then only counts, ids, previews, and redacted errors are shown by default.

#### TRD-008-TEST — Test status and diagnostics redaction (3h) [verifies TRD-008] [satisfies REQ-010, REQ-014]

Add tests for accepted/delivered/failed states, unknown id, diagnostics counts, and no-payload body leakage.

Validates PRD ACs: AC-010-2, AC-010-3, AC-014-1, AC-014-2

Implementation AC:

- Given status is requested for an unknown id, then `{:error, :not_found}` is returned.
- Given diagnostics are captured, then raw message bodies and attachment contents are absent.

#### TRD-009 — Add privacy-safe comms telemetry (3h) [satisfies REQ-010, REQ-012, REQ-014]

Extend `ForemanServer.Telemetry` with comms events such as `[:foreman, :comms, :message, :accepted]`, `:delivered`, `:failed`, `:ask, :timeout`, and `:mailbox, :dropped`.

Validates PRD ACs: AC-010-1, AC-012-3, AC-014-1, AC-014-2

Implementation AC:

- Given delivery state changes, when telemetry emits, then event metadata includes ids/state/reason class only.
- Given metadata has body-like or attachment content keys, when telemetry helper runs, then those keys are dropped or redacted.

#### TRD-009-TEST — Test telemetry taxonomy and scrubbing (3h) [verifies TRD-009] [satisfies REQ-010, REQ-012, REQ-014]

Add telemetry tests using existing attach handlers.

Validates PRD ACs: AC-010-1, AC-012-3, AC-014-1, AC-014-2

Implementation AC:

- Given comms lifecycle actions run, when telemetry handlers are attached, then expected event names and measurements are observed.
- Given payload content exists, when events are captured, then raw content is not present.

### PR 4: Ask/Reply and Pending Ask Workflows

**Shippable State:** Authorized agents can ask a target a blocking question, receive a correlated reply before timeout, handle timeout metadata, and inspect/reply to pending asks.

#### TRD-010 — Implement ask waiters with bounded timeout (7h) [satisfies REQ-006, REQ-010]

Implement `ask/3` by creating an ask message, storing waiter `GenServer.from()`, scheduling timeout, delivering to recipient, and replying to caller only when reply/timeout occurs. Avoid blocking inside the server callback beyond normal GenServer `from` retention.

Validates PRD ACs: AC-006-1, AC-006-2, AC-010-1

Implementation AC:

- Given a recipient replies before timeout, when the ask waiter is resolved, then the original caller receives the reply correlated by ask id.
- Given timeout fires first, when the server handles it, then caller receives `{:error, {:timeout, ask_id, delivery_state}}` and the ask is no longer pending.

#### TRD-010-TEST — Test ask success and timeout (5h) [verifies TRD-010] [satisfies REQ-006, REQ-010]

Add tests for successful reply, timeout, late reply rejection, recipient death, and concurrent asks.

Validates PRD ACs: AC-006-1, AC-006-2, AC-010-1

Implementation AC:

- Given a short test timeout, when no reply arrives, then the caller receives timeout within bounded wall-clock tolerance.
- Given a late reply after timeout, when `reply/3` runs, then it returns `{:error, {:not_pending, ask_id}}`.

#### TRD-011 — Implement reply disambiguation and pending inspection (5h) [satisfies REQ-006, REQ-007]

Implement `pending/1`, `reply(recipient, body)` for exactly one pending ask, and `reply(recipient, ask_id, body)` for explicit replies.

Validates PRD ACs: AC-006-3, AC-006-4, AC-007-1, AC-007-2

Implementation AC:

- Given exactly one unresolved ask for a recipient, when `reply/2` omits ask id, then it replies to that ask.
- Given multiple unresolved asks, when `reply/2` omits ask id, then it returns ambiguity and does not answer any ask.

#### TRD-011-TEST — Test pending and reply disambiguation (4h) [verifies TRD-011] [satisfies REQ-006, REQ-007]

Add tests for pending list fields, single-ask implicit reply, multi-ask ambiguity, explicit ask reply, and removal after answer/cancel/timeout.

Validates PRD ACs: AC-006-3, AC-006-4, AC-007-1, AC-007-2

Implementation AC:

- Given pending asks exist, when `pending/1` runs, then it returns ask ids, senders, timestamps, and previews only.
- Given an ask is answered, cancelled, or timed out, when `pending/1` runs again, then it is absent.

#### TRD-012 — Add ask/reply event-sink integration decision point (4h) [satisfies REQ-013]

Implement or stub `Comms.EventSink` behind config. If `:event_store` durability is enabled, append compatible lifecycle events using existing aggregate/command conventions; otherwise document in-code why in-memory is the active v1 mode.

Validates PRD ACs: AC-001-2, AC-013-1, AC-013-2, AC-013-3

Implementation AC:

- Given durability is disabled, when lifecycle events occur, then no EventStore write is attempted and status remains available in memory.
- Given durability is enabled in tests, when message append/delivery update occurs, then the event sink uses typed event payloads and does not duplicate incompatible inbox schemas.

#### TRD-012-TEST — Test event sink config and inbox compatibility (4h) [verifies TRD-012] [satisfies REQ-013]

Add tests for disabled sink, enabled sink with fake adapter or term EventStore, payload shape, and no direct projection mutation.

Validates PRD ACs: AC-001-2, AC-013-1, AC-013-2, AC-013-3

Implementation AC:

- Given event sink is enabled, when a lifecycle event emits, then it goes through an append adapter/command path rather than direct projection writes.
- Given existing `InboxThread` fields are insufficient, when tests inspect design adapters, then separation is explicit and typed.

### PR 5: Disconnected Mailbox, Operator Visibility, and Compatibility Shim

**Shippable State:** Temporarily disconnected named agents can receive bounded queued messages on reconnect, operators can inspect safe comms diagnostics, and optional pi-intercom-style action mapping is available through the Elixir façade.

#### TRD-013 — Implement bounded disconnected mailbox (6h) [satisfies REQ-008, REQ-010]

Add retained mailbox queues keyed by stable named session identity, TTL/capacity enforcement, reconnect delivery, at-most-once semantics, and drop accounting.

Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3, AC-010-1

Implementation AC:

- Given a retained named session is disconnected, when a message is sent, then the message is queued if under TTL/capacity and state becomes `:queued`.
- Given the session reconnects before expiry, when mailbox drain runs, then queued messages are delivered once and removed from the queue.

#### TRD-013-TEST — Test mailbox TTL, capacity, and reconnect delivery (5h) [verifies TRD-013] [satisfies REQ-008, REQ-010]

Add deterministic tests with injected clock or short TTL for queue, expiry, overflow, drops, reconnect drain, and at-most-once delivery.

Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3, AC-010-1

Implementation AC:

- Given mailbox capacity is exceeded, when a new message arrives, then the oldest/expired message is dropped according to documented policy and a drop count increments.
- Given reconnect delivery succeeds, when mailbox is inspected, then delivered messages are absent and status shows delivered/consumed path.

#### TRD-014 — Add operator diagnostics API (4h) [satisfies REQ-014]

Finalize `diagnostics/0` and optional debug-view helper with session count, pending ask count, mailbox depth, dropped count, recent safe delivery errors, and config summary.

Validates PRD ACs: AC-014-1, AC-014-2

Implementation AC:

- Given diagnostics are requested, when server has active and disconnected sessions, then counts and mailbox depths are accurate.
- Given sensitive bodies exist, when diagnostics output is inspected, then raw body and attachment content are absent unless a future explicit authorization mode is added.

#### TRD-014-TEST — Test diagnostics completeness and privacy (3h) [verifies TRD-014] [satisfies REQ-014]

Add tests for diagnostic counts, recent errors, previews, and privacy constraints.

Validates PRD ACs: AC-014-1, AC-014-2

Implementation AC:

- Given pending asks, queued messages, and dropped messages exist, when diagnostics runs, then all counts match server state.
- Given message content includes known sentinel text, when diagnostics runs, then sentinel text is not returned.

#### TRD-015 — Add optional pi-intercom-style action mapper (4h) [satisfies REQ-015]

Implement a thin internal mapper module such as `ForemanServer.Comms.Actions` that maps `list`, `list-cwd`, `send`, `ask`, `reply`, `pending`, and `status` action maps to façade calls. Do not add a CLI or HTTP route unless separately requested.

Validates PRD ACs: AC-015-1, AC-015-2

Implementation AC:

- Given an action map with supported action names, when `Actions.handle/2` runs, then it delegates to the façade and returns the same stable result shape.
- Given the mapper is disabled or omitted by callers, when the core façade is used, then all core behavior remains independently testable.

#### TRD-015-TEST — Test action mapper coverage (3h) [verifies TRD-015] [satisfies REQ-015]

Add tests for supported actions, unknown action rejection, argument normalization, and no external package dependency.

Validates PRD ACs: AC-015-1, AC-015-2

Implementation AC:

- Given each supported action is supplied, when the mapper handles it, then the expected façade function is invoked.
- Given source files are scanned, when dependency checks run, then no dependency on external `pi-intercom` exists.

## Dependency Graph

| Task | Depends On | Notes |
|---|---|---|
| TRD-001 | none | Public API contract first |
| TRD-001-TEST | TRD-001 | Validation and architecture boundary tests |
| TRD-002 | TRD-001 | Structs support façade validation and server state |
| TRD-002-TEST | TRD-002 | Unit contract tests |
| TRD-003 | TRD-001, TRD-002 | Server depends on contracts and structs |
| TRD-003-TEST | TRD-003 | Supervision tests |
| TRD-004 | TRD-003 | Presence is first live server capability |
| TRD-004-TEST | TRD-004 | Presence tests |
| TRD-005 | TRD-004 | Targeting requires presence indexes |
| TRD-005-TEST | TRD-005 | Target tests |
| TRD-006 | TRD-004, TRD-005 | Auth filters target/list results |
| TRD-006-TEST | TRD-006 | Auth tests |
| TRD-007 | TRD-002, TRD-005, TRD-006 | Send requires schema, target, auth |
| TRD-007-TEST | TRD-007 | Delivery tests |
| TRD-008 | TRD-007 | Status consumes delivery states |
| TRD-008-TEST | TRD-008 | Status tests |
| TRD-009 | TRD-007, TRD-008 | Telemetry across delivery/status |
| TRD-009-TEST | TRD-009 | Telemetry tests |
| TRD-010 | TRD-007, TRD-009 | Ask builds on send and telemetry |
| TRD-010-TEST | TRD-010 | Ask tests |
| TRD-011 | TRD-010 | Pending/reply resolves asks |
| TRD-011-TEST | TRD-011 | Pending tests |
| TRD-012 | TRD-007, TRD-010 | Event sink records send/ask lifecycle |
| TRD-012-TEST | TRD-012 | Event sink tests |
| TRD-013 | TRD-004, TRD-007, TRD-008 | Mailbox requires presence, send, status |
| TRD-013-TEST | TRD-013 | Mailbox tests |
| TRD-014 | TRD-008, TRD-013 | Diagnostics aggregate server state |
| TRD-014-TEST | TRD-014 | Diagnostics tests |
| TRD-015 | TRD-001, TRD-011, TRD-014 | Action mapper delegates to finished façade |
| TRD-015-TEST | TRD-015 | Mapper tests |

No circular dependencies identified. Longest chain is PR1 -> PR2 -> PR3 -> PR4 -> PR5; each PR has a user-observable façade capability and tests.

## Sprint Planning

## Sprint 1: Core Contracts and Presence

- PR 1: Public contracts, typed structs, supervision.
- PR 2: Presence, deterministic target resolution, authorization.

Exit criteria: local Elixir callers can register/list/resolve sessions safely, and unauthorized cross-scope messaging is denied before delivery.

## Sprint 2: Delivery and Ask/Reply

- PR 3: Send delivery, polling/callbacks, status, telemetry.
- PR 4: Ask/reply waiters, pending asks, event sink decision point.

Exit criteria: agents can send and ask/reply with bounded timeouts, correlated replies, privacy-safe telemetry, and pending recovery.

## Sprint 3: Mailbox and Compatibility

- PR 5: Bounded disconnected mailbox, diagnostics, optional action mapper.

Exit criteria: disconnected named sessions can receive bounded queued messages on reconnect, and operators can inspect safe diagnostics.

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Supervised communication server | TRD-003, TRD-012 | TRD-003-TEST, TRD-012-TEST |
| REQ-002 | Stable public façade | TRD-001 | TRD-001-TEST |
| REQ-003 | Session registration and presence | TRD-002, TRD-004 | TRD-002-TEST, TRD-004-TEST |
| REQ-004 | Target resolution | TRD-005 | TRD-005-TEST |
| REQ-005 | Fire-and-forget send | TRD-007 | TRD-007-TEST |
| REQ-006 | Blocking ask/reply workflow | TRD-010, TRD-011 | TRD-010-TEST, TRD-011-TEST |
| REQ-007 | Pending ask inspection | TRD-011 | TRD-011-TEST |
| REQ-008 | Bounded disconnected mailbox | TRD-013 | TRD-013-TEST |
| REQ-009 | Message schema and attachments | TRD-002 | TRD-002-TEST |
| REQ-010 | Delivery state tracking | TRD-002, TRD-007, TRD-008, TRD-009, TRD-010, TRD-013 | TRD-002-TEST, TRD-007-TEST, TRD-008-TEST, TRD-009-TEST, TRD-010-TEST, TRD-013-TEST |
| REQ-011 | Subscription or callback delivery | TRD-007 | TRD-007-TEST |
| REQ-012 | Local trust and authorization boundaries | TRD-006, TRD-009 | TRD-006-TEST, TRD-009-TEST |
| REQ-013 | Reuse existing inbox/event patterns | TRD-012 | TRD-012-TEST |
| REQ-014 | Operator/debug visibility | TRD-008, TRD-009, TRD-014 | TRD-008-TEST, TRD-009-TEST, TRD-014-TEST |
| REQ-015 | UI/CLI compatibility shim | TRD-001, TRD-015 | TRD-001-TEST, TRD-015-TEST |

Traceability check: 15 requirements covered, 0 uncovered, 0 orphaned annotations.

## Verification Plan

Run targeted tests after implementation:

```bash
cd packages/foreman_server
mix test test/foreman_server/comms
mix test test/foreman_server/application_test.exs test/foreman_server/architecture/alias_boundary_test.exs
mix test test/foreman_server/event_store_test.exs test/foreman_server/inbox/shared_inbox_test.exs
```

Recommended focused checks:

- Grep for forbidden direct `GenServer.call(ForemanServer.Comms.Server` outside `ForemanServer.Comms.*`.
- Capture telemetry and assert no message body, attachment content, credentials, or raw context fields are emitted.
- Use short test timeouts and injected clock/config for ask timeout and mailbox TTL tests.
- Confirm no dependency on external `pi-intercom` is added to Mix files.

## Architecture Self-Critique

| Issue | Impact | Recommended Resolution |
|---|---|---|
| Durability is still ambiguous in PRD | Crash recovery expectations differ between in-memory and EventStore-backed modes | Keep runtime state in GenServer for v1, but implement `EventSink` boundary and document default `:event_sink_optional`; require human refine before promising crash-surviving asks |
| Blocking asks can deadlock if implemented as nested `GenServer.call` chains | Server mailbox stalls and waiters may never resolve | Store `GenServer.from()` and reply asynchronously on reply/timeout; never call recipient synchronously from inside a long-running server call |
| Existing `InboxThread` is close but not sufficient | Duplicate schemas or conceptual drift could appear | Use `InboxThread` only for durable append/update integration when schema fits; keep direct session presence/routing in `Comms.Server` |
| Authorization scope lacks final product decision | Security leakage risk | Default to same project/cwd local scope and no remote access; make scope config explicit and tested |
| Diagnostics might leak sensitive context | Secrets/source snippets may be exposed | Return metadata/previews only; add sentinel redaction tests |

## Task Coverage Review

| Finding | Status |
|---|---|
| Every PRD REQ has implementation coverage | Covered |
| Every PRD REQ has test coverage | Covered |
| No TRD task references nonexistent REQ ids | Verified by matrix |
| Tasks >= 8h | None; largest task is 7h |
| PR sections include shippable state | Present for all 5 PRs |
| Infrastructure-only shippable states | None; each PR exposes observable façade behavior |

Coverage concerns:

1. REQ-013 depends on a design choice more than a single implementation task. Resolution: TRD-012 forces an explicit `EventSink` seam and compatibility tests.
2. REQ-015 is Could priority, but pi-intercom-style behavior motivated the prompt. Resolution: isolate it to PR 5 action mapper so core API remains complete if omitted.

## Dependency and Estimate Review

- Critical path depth is 5 PRs, acceptable for stacked implementation.
- No circular dependencies found.
- Similar tests are estimated 3–5h based on GenServer/telemetry/timeouts complexity.
- High-risk areas are ask timeout races, process monitor cleanup, mailbox TTL determinism, and telemetry redaction.

Estimate concern:

- TRD-010 ask/waiter implementation may exceed 7h if persistence of in-flight asks is required. Resolution: keep persisted ask recovery out of v1 unless PRD is refined; event sink records lifecycle but does not promise replayable waiters.

## Testability Review

All implementation ACs are measurable with ExUnit, state inspection through the façade, telemetry handlers, and deterministic config. Subjective terms are avoided except for “safe” diagnostics, defined here as metadata/previews without raw body or attachment content.

Testability concern:

- Callback/MFA delivery can create race-prone tests. Resolution: support pid delivery in tests and use MFA only with a deterministic test module that sends evidence to the test process.

## Design Readiness Scorecard

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4 | Components, state, data flow, errors, and config are defined; durability mode remains configurable because PRD is ambiguous |
| Task coverage | 4 | All 15 PRD requirements have implementation and test tasks |
| Dependency clarity | 4 | Dependencies are explicit, acyclic, and PR slices are shippable |
| Estimate confidence | 3 | Ask/reply races, mailbox TTL, and EventStore integration can expand if clarification changes scope |
| Overall | 3.8 | CONCERNS — Draft saved per Foreman mode |

## Notes

- Foreman mode was used. No user prompts, confirmation, team configuration, or readiness-gate halt was run.
- Auto-selected Option B for Draft; human refine pass can downgrade to Option A if in-memory v1 is enough.
- Source PRD has 13 `[NEEDS CLARIFICATION]` markers. This TRD uses conservative defaults but does not resolve product decisions authoritatively.
- v1 design assumes same BEAM node / local Foreman runtime usage, with same-project-or-cwd authorization by default.
- Crash-surviving in-flight asks are not promised by default; mailbox/session/message lifecycle durability requires the configured event sink and future refine if strict recovery is needed.
- MCP enhancement skipped because no MCP tools were available in this Pi tool session.

## Follow-Up

Suggested human refinement command:

```text
/ensemble:refine-trd docs/TRD/TRD-2026-b09923de-create-a-prd-trd-for-intercomm-style-inter-agent.md
```

Resolve before implementation if possible:

1. Confirm v1 consumers: Pi workers only, all agent-runtime adapters, CLI, Web UI, or external clients.
2. Confirm durability model: in-memory, event-audited, or replay/recovery semantics for asks/mailboxes.
3. Confirm trust scope: same BEAM node, OS user, project, cwd, or authenticated API clients.
4. Confirm default mailbox size/TTL and message/attachment size limits.
5. Confirm whether PR 5 compatibility mapper is required for v1 or may remain optional.
