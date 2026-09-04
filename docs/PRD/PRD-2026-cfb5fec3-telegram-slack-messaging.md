---
document_id: PRD-2026-cfb5fec3
label: prd-telegram-slack-messaging
version: 1.0.0
status: Draft
date: 2026-09-04
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 36
readiness_score: 3.8
---

# PRD: Telegram and Slack Messaging Integration

Foreman task title read from `FOREMAN_TASK_TITLE`: **Integrate Telegram Slack messaging**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 4 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Acceptance criteria coverage | 14/14 (100%) |
| Risk flags | 10 |
| Dependencies | 11 |
| Open ambiguity markers | 18 |
| TRD decisions required | 18 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Provide a messaging provider abstraction | Must | High | 3 |
| REQ-002 | Send operator-facing notifications | Must | High | 3 |
| REQ-003 | Support Telegram bot delivery | Must | High | 3 |
| REQ-004 | Preserve Slack delivery support | Must | Medium | 2 |
| REQ-005 | Configure channels safely per project/workflow | Must | High | 3 |
| REQ-006 | Notify refine/collab sessions with public URLs | Must | Medium | 2 |
| REQ-007 | Notify stalls, failures, and errors | Must | Medium | 3 |
| REQ-008 | Track delivery state and failures | Must | Medium | 2 |
| REQ-009 | Protect secrets and message contents | Must | High | 3 |
| REQ-010 | Keep delivery non-blocking for runs | Must | High | 3 |
| REQ-011 | Offer operator controls and opt-out | Should | Medium | 2 |
| REQ-012 | Document setup and troubleshooting | Should | Medium | 2 |
| REQ-013 | Test provider contracts and notification triggers | Should | Medium | 3 |
| REQ-014 | Leave room for additional messaging providers | Should | Medium | 2 |

## 1. Executive Summary

Foreman needs messaging as an operator communication channel, not as a replacement for the existing inbox, run projection, or command APIs. The requested product adds Telegram bot integration alongside existing Slack-oriented messaging expectations so Foreman can send task notifications, run updates, and operator alerts through configured channels.

The first valuable use case is restoring interactivity to long-running Foreman workflows. When `/refine-prd` or similar phases run with `--collab --long-lived`, Foreman should be able to send the exposed Cloudflare/public URL to the operator so they can refine PRDs/TRDs before continuation. The same messaging surface should also notify operators when runs stall, fail, or require attention.

Foreman mode auto-selected STANDARD depth. Interviews were skipped under `--foreman`; unresolved choices are marked inline with `[NEEDS CLARIFICATION: ...]` for `/ensemble-refine-prd`.

## 2. Background and Evidence

### 2.1 Product input

Task description: "Add Telegram bot integration alongside existing Slack integration. Enable Foreman to send task notifications, run updates, and operator alerts via Telegram as an alternative messaging channel."

Repository `prompts.md` also notes the desired motivation: messaging should let refine workflows return a long-lived public URL to the user, and should support stall detection, failure reporting, and other operator alerts.

### 2.2 Current codebase shape

Foreman is a multi-package repo:

- `packages/foreman_server` — Elixir/Phoenix/OTP backend, event store, projections, scheduler, inbox, run/task APIs, webhooks, MCP.
- `packages/foreman_cli` — Go CLI.
- `packages/jido_harness` — Elixir harness/provider integration.

Relevant existing boundaries:

- `ForemanServer.Inbox.SharedInbox.ingest/2` normalizes incoming inbox items and dedupes them by source correlation id.
- `ForemanServer.Agents.OperatorQuestionDispatcher` routes operator question events into the shared inbox and schedules operator timeouts.
- `ForemanServerWeb.WebhookController.operator_ingest/2` exposes `/webhooks/operator/ingest` for operator question ingestion.
- Existing docs list `/webhooks/operator/ingest`, GitHub webhook behavior, workflow/run lifecycles, and operator expectations.

### 2.3 Product problem

Foreman can run long-lived automated workflows, but the operator may not be watching the terminal or debug UI. Without messaging, phases that expose a collaboration URL, pause for operator input, stall, or fail may only surface inside local logs or run artifacts. That weakens unattended operation and makes Foreman less interactive at exactly the moments when a human decision is needed.

## 3. Personas

### 3.1 Foreman operator

Runs PRD/TRD/refine/implement workflows and wants timely notifications when action is needed, especially with links they can open immediately.

### 3.2 Workflow author

Defines which events should notify operators and what message text or severity should be sent.

### 3.3 Foreman maintainer

Needs a typed, testable messaging boundary that keeps provider-specific code out of scheduler/run logic and preserves existing event/projection contracts.

## 4. Scope

### In scope

- A provider-agnostic messaging service contract.
- Telegram bot delivery as a first-class provider.
- Preservation/integration of Slack delivery expectations [NEEDS CLARIFICATION: What existing Slack implementation or configuration should be treated as authoritative?].
- Task notifications, run updates, operator alerts, stall/failure/error notices.
- Sending refine/collaboration URLs generated by workflows.
- Configuration, secrets, tests, docs, and telemetry for messaging.

### Out of scope

- Building a full chat UI inside Foreman.
- Replacing `SharedInbox` or operator webhook ingestion.
- Two-way Telegram/Slack command execution unless explicitly added later [NEEDS CLARIFICATION: Should v1 accept inbound Telegram/Slack replies, or send-only?].
- Provider-specific rich UI beyond safe text/buttons/links supported by both providers.
- User account management for chat identities beyond configured recipients [NEEDS CLARIFICATION: Are per-user identities required, or is project/workflow-level recipient routing enough for v1?].

## 5. Assumptions From Foreman Mode

- STANDARD depth is sufficient for this PRD.
- Messaging is server-side Foreman behavior under `packages/foreman_server`.
- Telegram and Slack are external delivery providers behind one Foreman messaging abstraction.
- Initial messages are operator-facing outbound notifications.
- Secrets come from Foreman config/secrets mechanisms, not committed workflow YAML.
- Delivery failures should be visible but must not make core run progression depend on chat service uptime.

## 6. Requirements

### 6a. Messaging Core

### REQ-001: Provide a messaging provider abstraction

Priority: Must
Complexity: High
Risk: Provider-specific calls can leak into scheduler/run phases and create duplicate boundaries.

Foreman MUST expose one typed messaging service boundary that run/workflow code can use without knowing whether delivery is Telegram, Slack, or another provider.

- AC-001-1: Given a Foreman component requests an operator notification, when it calls the messaging boundary, then the request uses a provider-neutral message struct/schema with recipient, severity, subject, body, optional URL, correlation id, and metadata.
- AC-001-2: Given the configured provider is Telegram or Slack, when a provider-neutral notification is sent, then the provider adapter receives only normalized validated data and no unknown fields.
- AC-001-3: Given an unsupported provider is configured, when delivery is attempted, then Foreman returns/logs a typed configuration error and does not crash the caller.

### REQ-002: Send operator-facing notifications

Priority: Must
Complexity: High
Risk: Notification spam or missed delivery can make operators ignore Foreman alerts.

Foreman MUST send operator-facing notifications for configured task and run lifecycle events.

- AC-002-1: Given messaging is enabled for a project/workflow, when a task requires operator attention, then Foreman sends a notification identifying the task, run, workflow, severity, and requested action.
- AC-002-2: Given messaging is disabled, when the same event occurs, then no provider call is attempted and the run behavior remains unchanged.
- AC-002-3: Given multiple lifecycle events occur rapidly, when notifications are emitted, then Foreman dedupes or rate-limits repeated messages by correlation id/window [NEEDS CLARIFICATION: What default dedupe/rate-limit window should messaging use?].

### REQ-003: Support Telegram bot delivery

Priority: Must
Complexity: High
Risk: Telegram bot APIs expose chat ids and tokens that must be handled as secrets.

Foreman MUST support Telegram as an outbound delivery provider through a bot token and configured chat target.

- AC-003-1: Given a valid Telegram bot token and chat id are configured, when Foreman sends a message, then the operator receives a Telegram message containing the subject, body, severity, run/task identifiers, and link when present.
- AC-003-2: Given Telegram returns an API error, timeout, or rate limit, when delivery fails, then Foreman records a typed delivery failure with provider, status/reason, correlation id, and retry eligibility.
- AC-003-3: Given no Telegram token or chat id is configured, when Telegram is selected, then Foreman reports a configuration error before attempting network delivery.

### REQ-004: Preserve Slack delivery support

Priority: Must
Complexity: Medium
Risk: Adding Telegram can regress existing Slack behavior or docs.

Foreman MUST preserve existing Slack delivery behavior while adding Telegram as an alternative channel.

- AC-004-1: Given Slack is configured as the selected provider, when a notification is sent, then Foreman uses the existing Slack contract/configuration [NEEDS CLARIFICATION: Is Slack currently webhook-based, bot-token-based, or planned-only?].
- AC-004-2: Given both Slack and Telegram are configured, when project/workflow routing selects Slack, then Telegram is not called unless fanout is explicitly enabled [NEEDS CLARIFICATION: Should v1 support multi-provider fanout or exactly one provider per destination?].

### REQ-005: Configure channels safely per project/workflow

Priority: Must
Complexity: High
Risk: Misrouted messages can leak sensitive run/task context.

Foreman MUST allow safe configuration of messaging providers, destinations, and enablement at an appropriate scope.

- AC-005-1: Given global messaging defaults exist, when a project/workflow does not override them, then Foreman uses the defaults only if they are explicitly enabled.
- AC-005-2: Given a project/workflow override exists, when notifications are emitted, then Foreman routes to the configured provider/destination for that scope [NEEDS CLARIFICATION: Which configuration file/schema owns project and workflow messaging settings?].
- AC-005-3: Given a destination value is malformed, when Foreman loads config or attempts delivery, then it returns a typed validation error and never silently falls back to another destination.

### 6b. Notification Triggers

### REQ-006: Notify refine/collab sessions with public URLs

Priority: Must
Complexity: Medium
Risk: Collaboration links can be missed, expire, or be exposed to the wrong recipient.

Foreman MUST notify the operator when a workflow phase produces a long-lived collaboration URL for human refinement.

- AC-006-1: Given a refine/collab phase produces a public URL, when the URL is available, then Foreman sends a message containing the URL, run id, task id, phase id, and expiration/validity details [NEEDS CLARIFICATION: Which artifact/event exposes the collab URL and its TTL?].
- AC-006-2: Given the URL cannot be produced, when the phase needs human refinement, then Foreman sends a failure/action-needed notification without inventing a URL.

### REQ-007: Notify stalls, failures, and errors

Priority: Must
Complexity: Medium
Risk: Alert criteria can either spam operators or miss true failures.

Foreman MUST send operator alerts for stalled runs, failed phases, run failures, and notable system errors.

- AC-007-1: Given a run appears stalled by Foreman's stall detection rules, when the stall threshold is crossed, then Foreman sends a stall alert with run/task/workflow context and suggested next action [NEEDS CLARIFICATION: What source of truth defines “stalled” for v1?].
- AC-007-2: Given a phase fails or a run enters failed/cancelled status, when the terminal status is recorded, then Foreman sends one failure notification per run terminal transition.
- AC-007-3: Given an internal messaging provider error occurs, when it affects notification delivery, then Foreman records/logs the provider error without recursively sending more provider-error alerts.

### REQ-008: Track delivery state and failures

Priority: Must
Complexity: Medium
Risk: Without delivery state, operators cannot distinguish “not notified” from “not yet seen”.

Foreman MUST track notification delivery attempts enough for debugging and operator trust.

- AC-008-1: Given a notification is attempted, when delivery succeeds or fails, then Foreman records provider, destination reference, correlation id, timestamp, status, and failure reason when present.
- AC-008-2: Given a duplicate notification correlation id is seen inside the dedupe window, when delivery would repeat, then Foreman records/skips the duplicate according to documented policy [NEEDS CLARIFICATION: Should delivery state be event-sourced, projection-only, or log/telemetry only?].

### REQ-009: Protect secrets and message contents

Priority: Must
Complexity: High
Risk: Provider tokens, chat ids, task descriptions, and URLs may contain sensitive information.

Foreman MUST protect provider credentials and avoid leaking sensitive content in logs, artifacts, or telemetry.

- AC-009-1: Given Telegram/Slack credentials are configured, when config is loaded, logs/telemetry/errors never print raw tokens.
- AC-009-2: Given a notification contains task/run content, when it is rendered for chat, then Foreman includes only safe operator-facing fields by default [NEEDS CLARIFICATION: Which task/run fields are safe to include in chat messages?].
- AC-009-3: Given a provider response includes request headers or URLs, when Foreman records failure details, then secrets and private link tokens are redacted.

### REQ-010: Keep delivery non-blocking for runs

Priority: Must
Complexity: High
Risk: Chat provider downtime must not block scheduler progress or corrupt run state.

Messaging MUST NOT make core run execution depend on Telegram/Slack availability.

- AC-010-1: Given a run lifecycle event triggers a notification, when the provider is slow, then run state transition latency is not blocked beyond a small bounded enqueue/dispatch budget [NEEDS CLARIFICATION: What max enqueue/dispatch latency budget is acceptable?].
- AC-010-2: Given provider delivery fails permanently, when the run itself is otherwise healthy, then the run does not fail solely because notification delivery failed.
- AC-010-3: Given a notification is critical for operator action, when delivery fails, then Foreman exposes the failed notification in logs/projections/admin/debug UI [NEEDS CLARIFICATION: Which operator surface should display failed notifications?].

### 6c. Operator Experience, Docs, and Extensibility

### REQ-011: Offer operator controls and opt-out

Priority: Should
Complexity: Medium
Risk: Operators may disable all messaging if controls are too coarse.

Foreman SHOULD let operators control which event classes generate messages.

- AC-011-1: Given messaging is enabled, when an operator configures event classes, then Foreman can independently enable/disable collab URLs, action-needed prompts, stalls, failures, and generic run updates [NEEDS CLARIFICATION: Which event classes are required for v1?].
- AC-011-2: Given a notification would be sent for a disabled event class, when that event occurs, then Foreman suppresses provider delivery but preserves normal run behavior.

### REQ-012: Document setup and troubleshooting

Priority: Should
Complexity: Medium
Risk: Messaging relies on external provider setup that operators can misconfigure.

Foreman SHOULD document Telegram and Slack setup, configuration, security, and troubleshooting.

- AC-012-1: Given docs are updated, when an operator wants Telegram notifications, then docs explain bot creation, token secret wiring, chat id discovery, provider selection, and test delivery [NEEDS CLARIFICATION: Should Foreman include a CLI/API “send test message” command?].
- AC-012-2: Given delivery fails, when an operator checks troubleshooting docs, then docs distinguish auth failure, malformed destination, network error, rate limit, disabled messaging, and unsupported provider.

### REQ-013: Test provider contracts and notification triggers

Priority: Should
Complexity: Medium
Risk: Provider APIs and lifecycle triggers are easy to fake incorrectly.

Foreman SHOULD include tests that pin provider contracts, routing, policy, and trigger behavior.

- AC-013-1: Given Telegram adapter tests run, when requests are built, then tests assert endpoint, method, payload shape, timeout handling, and redaction without contacting Telegram.
- AC-013-2: Given Slack adapter tests run, when requests are built, then existing Slack behavior remains compatible [NEEDS CLARIFICATION: Which Slack contract must tests preserve?].
- AC-013-3: Given lifecycle trigger tests run, when collab URL, stall, failure, and action-needed events occur, then tests assert exactly one intended notification is enqueued per configured rule.

### REQ-014: Leave room for additional messaging providers

Priority: Should
Complexity: Medium
Risk: A hard-coded two-provider design will make future channels expensive.

Foreman SHOULD keep provider-specific behavior behind a reusable adapter interface.

- AC-014-1: Given a new provider is added later, when it implements the messaging provider behavior/contract, then scheduler/run code does not change.
- AC-014-2: Given provider-specific capabilities differ, when Foreman renders a message, then unsupported rich features degrade to safe plain text instead of failing delivery [NEEDS CLARIFICATION: Are buttons/interactive actions required for Telegram or Slack in v1?].

## 7. Dependency Map

- REQ-002 depends on REQ-001 and REQ-005.
- REQ-003 depends on REQ-001, REQ-005, REQ-009, and REQ-010.
- REQ-004 depends on REQ-001 and Slack source verification.
- REQ-005 depends on selected config/secrets boundaries.
- REQ-006 depends on REQ-001, REQ-002, REQ-005, and a verified collab URL event/artifact source.
- REQ-007 depends on REQ-001, REQ-002, and verified stall/failure event sources.
- REQ-008 depends on REQ-001 and may depend on event/projection design chosen in TRD.
- REQ-009 is a prerequisite for REQ-003, REQ-004, REQ-006, REQ-007, and REQ-008.
- REQ-010 is a prerequisite for all trigger-based notifications.
- REQ-011 depends on REQ-005.
- REQ-012 and REQ-013 depend on all implementation-scope requirements.
- REQ-014 depends on REQ-001.

Recommended implementation clusters:

1. Messaging contract/config/secrets: REQ-001, REQ-005, REQ-009, REQ-010.
2. Provider adapters: REQ-003, REQ-004, REQ-014.
3. Trigger integration: REQ-002, REQ-006, REQ-007, REQ-008, REQ-011.
4. Docs/tests: REQ-012, REQ-013.

No circular dependencies identified.

## 8. Adversarial Review

Foreman mode auto-applied safe resolutions and left unresolved decisions inline.

1. **Gap: Slack source of truth unclear.** Resolution: require TRD to verify whether Slack exists in source, docs, config, or only product expectation; mark Slack contract questions inline.
2. **Ambiguity: send-only vs two-way chat.** Resolution: scope v1 to outbound notifications, with inbound replies marked as out of scope unless refined.
3. **Risk: notification spam.** Resolution: require dedupe/rate limiting by correlation id, with exact window requiring clarification.
4. **Risk: provider downtime blocking runs.** Resolution: require non-blocking enqueue/dispatch semantics and delivery failure state.
5. **Security gap: chat messages can leak task/run data.** Resolution: require redaction, safe-field policy, and secret-safe errors.
6. **Integration gap: collab URL source unknown.** Resolution: require TRD source verification and inline clarification marker.
7. **Testability gap: “stalled” lacks a verified source.** Resolution: require TRD to locate/define authoritative stall detection source before implementation.

## 9. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Core providers, triggers, safety, docs, tests covered. |
| Testability | 4 | ACs are measurable, but some source contracts need TRD verification. |
| Clarity | 3 | Open ambiguity markers remain around Slack, config scope, URLs, and event classes. |
| Feasibility | 4 | Fits existing Elixir/Phoenix/OTP architecture and external provider APIs. |
| Overall | 3.8 | CONCERNS; saved under Foreman mode default. |

Gate decision: **CONCERNS — proceed under `--foreman`**. The PRD is ready for TRD creation only if the TRD explicitly resolves or preserves all `[NEEDS CLARIFICATION]` markers.

## 10. Suggested Next Step

Run:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-cfb5fec3-telegram-slack-messaging.md
```
