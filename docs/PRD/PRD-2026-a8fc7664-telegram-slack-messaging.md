---
document_id: PRD-2026-a8fc7664
label: prd-telegram-slack-messaging
version: 1.0.0
status: Draft
date: 2026-09-05
scale_depth: STANDARD
total_requirements: 16
total_acceptance_criteria: 38
readiness_score: 4.5
---

# PRD: Telegram and Slack Messaging Integration

Foreman task title read from `FOREMAN_TASK_TITLE`: **Integrate Telegram Slack messaging**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 5 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 16/16 (100%) |
| Acceptance criteria coverage | 16/16 (100%) |
| Risk flags | 11 |
| Dependencies | 14 |
| Open ambiguity markers | 0 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Keep one provider-neutral notification boundary | Must | High | 3 |
| REQ-002 | Resolve messaging config safely | Must | High | 3 |
| REQ-003 | Deliver Telegram bot notifications | Must | High | 3 |
| REQ-004 | Deliver Slack webhook notifications | Must | High | 3 |
| REQ-005 | Render only safe operator-facing content | Must | High | 2 |
| REQ-006 | Preserve async, non-blocking run progress | Must | High | 3 |
| REQ-007 | Track notification lifecycle state | Must | Medium | 2 |
| REQ-008 | Notify collaboration URLs | Must | Medium | 2 |
| REQ-009 | Notify stalls and recovery-worthy inactivity | Must | Medium | 2 |
| REQ-010 | Notify failures and action-needed events | Must | Medium | 3 |
| REQ-011 | Suppress duplicates and noisy updates | Must | Medium | 2 |
| REQ-012 | Provide test-delivery operator flow | Should | Medium | 2 |
| REQ-013 | Expose delivery state in read surfaces | Should | Medium | 2 |
| REQ-014 | Document setup and troubleshooting | Should | Medium | 2 |
| REQ-015 | Test provider contracts and triggers | Should | Medium | 3 |
| REQ-016 | Keep the provider interface extensible | Should | Medium | 1 |

## 1. Executive Summary

Foreman needs outbound messaging so operators learn about important workflow events without watching a terminal, dashboard, or run log. This PRD defines Telegram bot delivery and Slack webhook delivery behind a single Foreman messaging abstraction. Messaging must send task notifications, run updates, collaboration URLs, stalls, failures, and operator-alert events while preserving run correctness when chat providers are unavailable.

Foreman mode auto-selected STANDARD depth. Interviews were skipped by contract; product assumptions were resolved from the task description and repository evidence.

Ambiguity scan complete: 0 items marked for clarification.

## 2. Background and Evidence

Product input: "Add Telegram bot integration alongside existing Slack integration. Enable Foreman to send task notifications, run updates, and operator alerts via Telegram as an alternative messaging channel. Follow existing Slack messaging patterns and configuration."

Current source evidence:

- `packages/foreman_server/lib/foreman_server/messaging.ex` exposes `ForemanServer.Messaging.notify/2` as a fast enqueue boundary with a 250 ms dispatch timeout.
- `packages/foreman_server/lib/foreman_server/messaging/notification.ex` defines provider-neutral notification fields and allowed providers `:telegram` and `:slack`.
- `packages/foreman_server/lib/foreman_server/messaging/config_resolver.ex` resolves app/project/workflow config, supports `:telegram` and `:slack`, validates event classes, and defaults to disabled messaging.
- `packages/foreman_server/lib/foreman_server/aggregates/notification.ex` records enqueue, suppression, attempt, success, and failure lifecycle events.
- `packages/foreman_server/lib/foreman_server/messaging/renderer.ex` renders safe text through `Redactor`.
- `packages/foreman_server/lib/foreman_server/recovery.ex` detects stale active runs using `ProjectionStore.list_runs/0`, `last_event_at`, and a default 5-minute threshold.
- `packages/foreman_server/lib/foreman_server/agents/jido_signal_topics.ex` names `com.foreman.inbox.*` as the human-facing agent-to-operator notification bus.

## 3. Problem

Foreman workflows can run unattended, stall, fail, or pause for human refinement. Without reliable external alerts, operators discover issues late and miss public collaboration URLs or action requests. Existing server state should remain the source of truth, but Telegram and Slack should mirror urgent operator-facing events to configured chat destinations.

## 4. Personas

- **Foreman operator:** wants timely links, failures, stalls, and action requests in a preferred chat app.
- **Workflow author:** wants predictable event classes and config that avoid alert spam.
- **Foreman maintainer:** wants typed boundaries, no provider leakage into run logic, and testable contracts.

## 5. Scope

### In scope

- Outbound, send-only Telegram bot notifications.
- Outbound, send-only Slack incoming webhook notifications.
- Config resolution for application, project, and workflow layers.
- Event classes: `collab_url`, `action_needed`, `stall`, `failure`, `run_update`, and `test`.
- Delivery attempt/result tracking, redaction, docs, and tests.
- Non-blocking enqueue with asynchronous provider I/O.

### Out of scope

- Inbound Telegram/Slack commands or chat replies.
- A full chat UI in Foreman.
- Multi-provider fanout for one destination in v1.
- Provider-specific rich interactions beyond safe text and optional URLs.
- Persisting personal chat identity mappings beyond configured destinations.

## 6. Assumptions From Foreman Mode

- Messaging is server-side Foreman behavior under `packages/foreman_server`.
- Existing `ForemanServer.Messaging` DTO/config/aggregate modules are reusable foundations.
- Slack delivery means incoming webhook delivery unless implementation discovers a stronger existing runtime contract.
- Telegram delivery uses the Bot API `sendMessage` flow.
- Provider downtime must never fail an otherwise healthy run.

## 7. Requirements

### 7a. Messaging Core

### REQ-001: Keep one provider-neutral notification boundary

Priority: Must  
Complexity: High  
Risk: Provider-specific logic can leak into scheduler/run code.

Foreman MUST route operator notifications through a single provider-neutral messaging boundary.

- AC-001-1: Given any Foreman component emits a notification, when it calls the boundary, then the payload contains only normalized provider-neutral fields: provider, recipient, event class, severity, subject, body, optional URL, correlation id, run id, and safe metadata.
- AC-001-2: Given an unknown field is supplied, when notification normalization runs, then Foreman returns a typed validation error and does not enqueue the notification.
- AC-001-3: Given a future provider is added, when it implements the provider behavior, then scheduler/recovery/run code does not change.

### REQ-002: Resolve messaging config safely

Priority: Must  
Complexity: High  
Risk: Misconfigured destinations can leak sensitive run context.

Foreman MUST resolve messaging enablement, provider, event classes, rate limits, and destinations through deterministic config precedence.

- AC-002-1: Given workflow, project, and application messaging config exist, when Foreman resolves config, then workflow config overrides project config, which overrides application defaults.
- AC-002-2: Given messaging is not explicitly enabled, when a notification event occurs, then no provider network call is attempted.
- AC-002-3: Given destination config is missing or malformed for the selected provider, when messaging is enabled, then Foreman returns a typed validation error and never falls back to another destination.

### REQ-003: Deliver Telegram bot notifications

Priority: Must  
Complexity: High  
Risk: Bot tokens and chat ids are sensitive and Telegram API failures must not block Foreman.

Foreman MUST deliver configured notifications to Telegram via bot token and chat id.

- AC-003-1: Given Telegram is enabled with a valid token reference and chat id, when a notification is delivered, then the operator receives a Telegram message with severity, subject, body, relevant ids, and URL when present.
- AC-003-2: Given Telegram returns auth, rate-limit, timeout, or network failure, when delivery is attempted, then Foreman records a typed failure with retry eligibility and redacted details.
- AC-003-3: Given Telegram config is invalid, when test delivery or runtime delivery is requested, then Foreman reports `telegram_destination` validation failure before any provider call.

### REQ-004: Deliver Slack webhook notifications

Priority: Must  
Complexity: High  
Risk: Telegram work can regress Slack or produce divergent behavior.

Foreman MUST deliver configured notifications to Slack via incoming webhook as the Slack v1 provider contract.

- AC-004-1: Given Slack is enabled with a valid webhook URL reference, when a notification is delivered, then the configured Slack channel receives a message with the same operator-facing fields as Telegram.
- AC-004-2: Given Slack returns auth, rate-limit, timeout, or network failure, when delivery is attempted, then Foreman records a typed failure with retry eligibility and redacted details.
- AC-004-3: Given both Telegram and Slack config exist, when provider is set to Slack, then Telegram is not called for that notification.

### REQ-005: Render only safe operator-facing content

Priority: Must  
Complexity: High  
Risk: Prompts, environment values, artifacts, tokens, and private URLs may leak through chat.

Foreman MUST render chat content from an allowlist and redact sensitive details before delivery, logging, telemetry, or persistence.

- AC-005-1: Given a notification includes metadata, when it is normalized/rendered, then only allowlisted metadata keys are retained and unsafe keys are dropped.
- AC-005-2: Given a provider error or URL contains credentials or tokens, when Foreman records it, then secrets are redacted in events, logs, telemetry, and operator-facing output.

### REQ-006: Preserve async, non-blocking run progress

Priority: Must  
Complexity: High  
Risk: Chat provider outages can otherwise stall or fail unrelated workflows.

Messaging MUST NOT make core run execution depend on Telegram or Slack availability.

- AC-006-1: Given a run lifecycle event triggers a notification, when the event is accepted, then local enqueue completes within the existing 250 ms budget or returns a local enqueue error without blocking provider I/O.
- AC-006-2: Given provider delivery fails permanently, when the run itself is healthy, then the run does not fail solely because notification delivery failed.
- AC-006-3: Given Foreman restarts after enqueue and before delivery, when notification delivery resumes or is inspected, then persisted notification state is sufficient to avoid silent loss or duplicate provider sends beyond the dedupe policy.

### REQ-007: Track notification lifecycle state

Priority: Must  
Complexity: Medium  
Risk: Operators cannot debug missed alerts without attempt/result state.

Foreman MUST record notification enqueue, suppression, delivery attempt, success, and failure state.

- AC-007-1: Given a notification is enqueued, suppressed, attempted, succeeds, or fails, when the aggregate handles the command, then it records provider, correlation id, run id when present, status, sequence, attempt id, and failure reason when present.
- AC-007-2: Given duplicate or disabled notifications are suppressed, when read surfaces inspect the notification, then the suppression reason is visible and distinguishable from provider failure.

### 7b. Notification Triggers

### REQ-008: Notify collaboration URLs

Priority: Must  
Complexity: Medium  
Risk: Operators can miss expiring refinement links.

Foreman MUST notify operators when a workflow phase produces a public or local collaboration URL for human refinement.

- AC-008-1: Given a phase output or structured artifact contains a collaboration URL, when the URL is available, then Foreman sends a `collab_url` notification with run id, task id when available, phase id/name, URL, and validity/expiration text when known.
- AC-008-2: Given a collaboration phase needs action but no URL is available, when notification is emitted, then Foreman sends an `action_needed` or `failure` notification that does not invent a URL.

### REQ-009: Notify stalls and recovery-worthy inactivity

Priority: Must  
Complexity: Medium  
Risk: Stall alerts can spam operators or miss genuinely stuck runs.

Foreman MUST notify operators when stale active runs cross the configured recovery threshold.

- AC-009-1: Given `Recovery.do_detect/1` classifies an active run as stale, when the stale threshold is crossed, then Foreman sends one `stall` notification with run/task/workflow context and suggested next action.
- AC-009-2: Given the same run remains stale, when repeated scans occur within the dedupe window, then duplicate stall notifications are suppressed by correlation id.

### REQ-010: Notify failures and action-needed events

Priority: Must  
Complexity: Medium  
Risk: Missing terminal/failure alerts defeats the primary operator value.

Foreman MUST notify operators when phases/runs fail or when an operator action is required.

- AC-010-1: Given a phase fails, when Foreman records the phase failure, then it emits one `failure` notification with phase, run, workflow, and redacted reason.
- AC-010-2: Given a run enters a terminal failed or cancelled state, when the status transition is recorded, then Foreman emits one run-level failure notification.
- AC-010-3: Given an agent/operator question requires human input, when the action request is created, then Foreman emits one `action_needed` notification with the requested action and safe identifiers.

### REQ-011: Suppress duplicates and noisy updates

Priority: Must  
Complexity: Medium  
Risk: Unbounded chat noise trains operators to ignore Foreman alerts.

Foreman MUST dedupe repeated notifications and keep routine run updates opt-in or rate-limited.

- AC-011-1: Given the same correlation id is enqueued within the configured dedupe window, when Foreman handles the notification, then it records `NotificationSuppressed` with reason `duplicate` and does not call the provider.
- AC-011-2: Given `run_update` event class is disabled or rate-limited, when routine run updates occur, then Foreman suppresses provider delivery while preserving core run behavior.

### 7c. Operator Experience, Docs, and Quality

### REQ-012: Provide test-delivery operator flow

Priority: Should  
Complexity: Medium

Foreman SHOULD provide a CLI/API operation that lets operators verify Telegram or Slack config without running a full workflow.

- AC-012-1: Given messaging config is valid, when an operator invokes test delivery, then Foreman sends a `test` notification and reports provider, destination reference, and delivery status.
- AC-012-2: Given config is invalid, when test delivery is invoked, then Foreman reports the same validation errors used at runtime.

### REQ-013: Expose delivery state in read surfaces

Priority: Should  
Complexity: Medium

Foreman SHOULD expose notification delivery state in operator/debug read paths.

- AC-013-1: Given a run has notification attempts, when an operator reads run detail through existing server/CLI/MCP surfaces, then latest notification status is visible without reading raw event logs.
- AC-013-2: Given notification delivery failed, when read surfaces render the failure, then they show redacted provider/reason/correlation details and suggested troubleshooting class.

### REQ-014: Document setup and troubleshooting

Priority: Should  
Complexity: Medium

Foreman SHOULD document Telegram and Slack setup, config, secrets, test delivery, and troubleshooting.

- AC-014-1: Given an operator wants Telegram, when reading docs, then they can create a bot, locate a chat id, configure secret references, enable event classes, and run test delivery.
- AC-014-2: Given delivery fails, when reading troubleshooting docs, then they can distinguish disabled config, malformed destination, auth failure, network timeout, rate limit, provider outage, and redaction behavior.

### REQ-015: Test provider contracts and triggers

Priority: Should  
Complexity: Medium

Foreman SHOULD include tests that pin provider payloads, redaction, config precedence, notification lifecycle, and trigger wiring.

- AC-015-1: Given Telegram adapter tests run, when payloads are built, then tests assert endpoint, method, body shape, timeout handling, retry classification, and redaction without contacting Telegram.
- AC-015-2: Given Slack adapter tests run, when payloads are built, then tests assert webhook request shape, timeout handling, retry classification, and redaction without contacting Slack.
- AC-015-3: Given lifecycle trigger tests run, when collab URL, stall, failure, action-needed, duplicate, disabled, and test events occur, then tests assert exactly the intended enqueue/suppression/delivery commands.

### REQ-016: Keep the provider interface extensible

Priority: Should  
Complexity: Medium

Foreman SHOULD keep provider-specific code behind the `ForemanServer.Messaging.Provider` behavior.

- AC-016-1: Given a new provider implements the provider behavior and config validation, when it is selected, then existing notification DTO, aggregate lifecycle, rendering, and trigger code are reused.

## 8. Dependency Map

- REQ-002 depends on REQ-001.
- REQ-003 depends on REQ-001, REQ-002, REQ-005, REQ-006, and REQ-007.
- REQ-004 depends on REQ-001, REQ-002, REQ-005, REQ-006, and REQ-007.
- REQ-005 is a prerequisite for all provider delivery and read surfaces.
- REQ-006 depends on REQ-007 for persisted lifecycle state.
- REQ-008 depends on REQ-001, REQ-002, REQ-006, and phase output/artifact URL detection.
- REQ-009 depends on REQ-001, REQ-002, REQ-006, `Recovery.do_detect/1`, and dedupe.
- REQ-010 depends on REQ-001, REQ-002, REQ-006, and failure/action-needed event sources.
- REQ-011 depends on REQ-002 and REQ-007.
- REQ-012 depends on REQ-003 and REQ-004.
- REQ-013 depends on REQ-007.
- REQ-014 depends on REQ-002, REQ-003, REQ-004, REQ-012, and REQ-013.
- REQ-015 depends on all implementation-scope requirements.
- REQ-016 depends on REQ-001.

Recommended implementation clusters:

1. Config/DTO/lifecycle verification: REQ-001, REQ-002, REQ-005, REQ-007, REQ-011.
2. Provider delivery adapters: REQ-003, REQ-004, REQ-006, REQ-016.
3. Trigger/read surfaces: REQ-008, REQ-009, REQ-010, REQ-013.
4. Operator validation and docs: REQ-012, REQ-014, REQ-015.

No circular dependencies identified.

## 9. Adversarial Review

Foreman mode auto-applied these resolutions:

1. **Existing foundation risk:** Current source already has messaging DTO/config/aggregate modules, so requirements demand reuse instead of a parallel subsystem.
2. **Provider scope risk:** v1 is outbound send-only. Inbound chat replies/commands remain out of scope.
3. **Slack ambiguity:** Slack is specified as incoming webhook delivery unless implementation source verification finds a stronger existing runtime adapter.
4. **Secret leakage risk:** Safe metadata allowlisting and redaction are mandatory, not optional polish.
5. **Run-blocking risk:** Provider I/O must remain async; the existing 250 ms local enqueue budget is the user-visible requirement.
6. **Alert-spam risk:** Dedupe by correlation id and routine `run_update` controls are required.
7. **Missed collab link risk:** Collaboration URL notification is explicitly included, with no invented URL on failure.
8. **Observability gap:** Delivery state must surface in read paths, not only raw event logs.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 5 | Providers, config, lifecycle, triggers, safety, docs, tests, and read surfaces covered. |
| Testability | 5 | ACs pin config precedence, provider payloads, trigger behavior, redaction, and delivery state. |
| Clarity | 4 | The product boundary is clear; TRD still must map exact event-source hooks and worker placement. |
| Feasibility | 4 | Fits existing Elixir/Phoenix/OTP messaging foundation and event aggregate model. |
| Overall | 4.5 | READY. |

Gate decision: **READY — save PRD and proceed to TRD creation after approval.**

## 11. Suggested Next Step

```bash
/ensemble-create-trd docs/PRD/PRD-2026-a8fc7664-telegram-slack-messaging.md
```
