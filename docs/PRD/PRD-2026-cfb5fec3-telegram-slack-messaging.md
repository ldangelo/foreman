---
document_id: PRD-2026-cfb5fec3
label: prd-telegram-slack-messaging
version: 1.0.1
status: Draft
date: 2026-09-04
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 36
readiness_score: 4.4
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
| Risk flags | 14 |
| Dependencies | 12 |
| Open ambiguity markers | 0 |
| TRD decisions required | 0 |

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

Foreman mode auto-selected STANDARD depth. `/ensemble-refine-prd --foreman` auto-applied 18 clarification findings with source-backed defaults; no inline clarification markers remain.

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
- Repository search found no concrete Slack or Telegram adapter/config implementation; existing Slack/Telegram references describe a planned, unbuilt user-facing warning/error channel (`docs/PRD/PRD-2026-d306444f-phase-commit-control.md`).
- `ForemanServer.Recovery.do_detect/1` defines stale active-run detection from `ProjectionStore.list_runs/0`, `last_event_at`, and `:foreman_server, :run_stale_after_ms` with a default of 5 minutes.
- `ForemanServer.Workflow.RunExecutor.emit_phase_failure/4` and `emit_run_failure/2` are the current phase/run failure emission points.
- `ForemanServer.Agents.JidoSignalTopics.foreman_inbox/0` documents `com.foreman.inbox.*` as the agent-to-operator human-facing notification bus.
- `prompts.md` names the refine `--collab --long-lived` Cloudflare/public URL notification as the first desired messaging use case.

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
- Slack support as a newly implemented provider contract; current source/docs show Slack as planned, not implemented, so there is no existing runtime Slack adapter to preserve.
- Task notifications, run updates, operator alerts, stall/failure/error notices.
- Sending refine/collaboration URLs generated by workflows.
- Configuration, secrets, tests, docs, and telemetry for messaging.

### Out of scope

- Building a full chat UI inside Foreman.
- Replacing `SharedInbox` or operator webhook ingestion.
- Two-way Telegram/Slack command execution; v1 is send-only outbound notifications.
- Provider-specific rich UI beyond safe text/buttons/links supported by both providers.
- User account management for chat identities beyond configured recipients; project/workflow-level recipient routing is sufficient for v1.

## 5. Assumptions From Foreman Mode

- STANDARD depth is sufficient for this PRD.
- Messaging is server-side Foreman behavior under `packages/foreman_server`.
- Telegram and Slack are external delivery providers behind one Foreman messaging abstraction.
- Initial messages are operator-facing outbound notifications only; inbound chat replies/commands are deferred.
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
- AC-002-3: Given multiple lifecycle events occur rapidly, when notifications are emitted, then Foreman dedupes repeated messages by correlation id inside a configurable 5-minute default window and rate-limits noisy run-update classes separately from critical action/failure alerts.

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

- AC-004-1: Given Slack is configured as the selected provider, when a notification is sent, then Foreman uses a new Slack incoming-webhook adapter contract unless TRD source verification finds an existing runtime adapter before implementation.
- AC-004-2: Given both Slack and Telegram are configured, when project/workflow routing selects Slack, then Telegram is not called; v1 supports exactly one provider per destination and leaves multi-provider fanout out of scope.

### REQ-005: Configure channels safely per project/workflow

Priority: Must
Complexity: High
Risk: Misrouted messages can leak sensitive run/task context.

Foreman MUST allow safe configuration of messaging providers, destinations, and enablement at an appropriate scope.

- AC-005-1: Given global messaging defaults exist, when a project/workflow does not override them, then Foreman uses the defaults only if they are explicitly enabled.
- AC-005-2: Given a project/workflow override exists, when notifications are emitted, then Foreman resolves messaging configuration in this order: explicit workflow manifest notification settings, persisted Project configuration, then `:foreman_server, :messaging` application defaults.
- AC-005-3: Given a destination value is malformed, when Foreman loads config or attempts delivery, then it returns a typed validation error and never silently falls back to another destination.

### 6b. Notification Triggers

### REQ-006: Notify refine/collab sessions with public URLs

Priority: Must
Complexity: Medium
Risk: Collaboration links can be missed, expire, or be exposed to the wrong recipient.

Foreman MUST notify the operator when a workflow phase produces a long-lived collaboration URL for human refinement.

- AC-006-1: Given a refine/collab phase produces `Local:`, `Public:`, or `URL:` output or a structured artifact containing a public review URL, when the URL is available, then Foreman emits a structured notification event and sends a message containing the URL, run id, task id, phase id, and expiration/validity details.
- AC-006-2: Given the URL cannot be produced, when the phase needs human refinement, then Foreman sends a failure/action-needed notification without inventing a URL.

### REQ-007: Notify stalls, failures, and errors

Priority: Must
Complexity: Medium
Risk: Alert criteria can either spam operators or miss true failures.

Foreman MUST send operator alerts for stalled runs, failed phases, run failures, and notable system errors.

- AC-007-1: Given `ForemanServer.Recovery.do_detect/1` classifies an active run as stale using `ProjectionStore.list_runs/0`, `last_event_at`, and `:run_stale_after_ms` (default 5 minutes), when the stale threshold is crossed, then Foreman sends one stall alert with run/task/workflow context and suggested next action.
- AC-007-2: Given a phase fails or a run enters failed/cancelled status, when the terminal status is recorded, then Foreman sends one failure notification per run terminal transition.
- AC-007-3: Given an internal messaging provider error occurs, when it affects notification delivery, then Foreman records/logs the provider error without recursively sending more provider-error alerts.

### REQ-008: Track delivery state and failures

Priority: Must
Complexity: Medium
Risk: Without delivery state, operators cannot distinguish “not notified” from “not yet seen”.

Foreman MUST track notification delivery attempts enough for debugging and operator trust.

- AC-008-1: Given a notification is attempted, when delivery succeeds or fails, then Foreman records provider, destination reference, correlation id, timestamp, status, and failure reason when present.
- AC-008-2: Given a duplicate notification correlation id is seen inside the dedupe window, when delivery would repeat, then Foreman records/skips the duplicate through an event-sourced notification attempt/result contract, projects current delivery state for reads, and emits telemetry/logs from that source of truth.

### REQ-009: Protect secrets and message contents

Priority: Must
Complexity: High
Risk: Provider tokens, chat ids, task descriptions, and URLs may contain sensitive information.

Foreman MUST protect provider credentials and avoid leaking sensitive content in logs, artifacts, or telemetry.

- AC-009-1: Given Telegram/Slack credentials are configured, when config is loaded, logs/telemetry/errors never print raw tokens.
- AC-009-2: Given a notification contains task/run content, when it is rendered for chat, then Foreman includes only safe operator-facing fields by default: provider-neutral severity, subject, run id, task id, workflow id/name, phase id/name, terminal status, short action summary, public collaboration URL plus expiry when present, and redacted failure reason; prompts, environment variables, raw artifacts, provider credentials, private tokens, and full task descriptions are excluded unless explicitly allowed.
- AC-009-3: Given a provider response includes request headers or URLs, when Foreman records failure details, then secrets and private link tokens are redacted.

### REQ-010: Keep delivery non-blocking for runs

Priority: Must
Complexity: High
Risk: Chat provider downtime must not block scheduler progress or corrupt run state.

Messaging MUST NOT make core run execution depend on Telegram/Slack availability.

- AC-010-1: Given a run lifecycle event triggers a notification, when the provider is slow, then run state transition latency is not blocked beyond a 250 ms local enqueue budget; provider I/O occurs asynchronously after the run event is accepted.
- AC-010-2: Given provider delivery fails permanently, when the run itself is otherwise healthy, then the run does not fail solely because notification delivery failed.
- AC-010-3: Given a notification is critical for operator action, when delivery fails, then Foreman exposes the failed notification in `ProjectionStore` run detail, MCP run-status/read APIs, and server logs; any future admin/debug UI must read the same projection.

### 6c. Operator Experience, Docs, and Extensibility

### REQ-011: Offer operator controls and opt-out

Priority: Should
Complexity: Medium
Risk: Operators may disable all messaging if controls are too coarse.

Foreman SHOULD let operators control which event classes generate messages.

- AC-011-1: Given messaging is enabled, when an operator configures event classes, then Foreman can independently enable/disable v1 classes `collab_url`, `action_needed`, `stall`, `failure`, and `run_update`, with `run_update` opt-in to prevent noise.
- AC-011-2: Given a notification would be sent for a disabled event class, when that event occurs, then Foreman suppresses provider delivery but preserves normal run behavior.

### REQ-012: Document setup and troubleshooting

Priority: Should
Complexity: Medium
Risk: Messaging relies on external provider setup that operators can misconfigure.

Foreman SHOULD document Telegram and Slack setup, configuration, security, and troubleshooting.

- AC-012-1: Given docs are updated, when an operator wants Telegram notifications, then docs explain bot creation, token secret wiring, chat id discovery, provider selection, and the required Foreman test-delivery operation exposed through CLI or API.
- AC-012-2: Given delivery fails, when an operator checks troubleshooting docs, then docs distinguish auth failure, malformed destination, network error, rate limit, disabled messaging, and unsupported provider.

### REQ-013: Test provider contracts and notification triggers

Priority: Should
Complexity: Medium
Risk: Provider APIs and lifecycle triggers are easy to fake incorrectly.

Foreman SHOULD include tests that pin provider contracts, routing, policy, and trigger behavior.

- AC-013-1: Given Telegram adapter tests run, when requests are built, then tests assert endpoint, method, payload shape, timeout handling, and redaction without contacting Telegram.
- AC-013-2: Given Slack adapter tests run, when requests are built, then tests assert the new Slack incoming-webhook adapter endpoint, method, payload shape, timeout handling, and redaction without contacting Slack; if TRD source verification finds an existing adapter, those tests must also preserve that contract.
- AC-013-3: Given lifecycle trigger tests run, when collab URL, stall, failure, and action-needed events occur, then tests assert exactly one intended notification is enqueued per configured rule.

### REQ-014: Leave room for additional messaging providers

Priority: Should
Complexity: Medium
Risk: A hard-coded two-provider design will make future channels expensive.

Foreman SHOULD keep provider-specific behavior behind a reusable adapter interface.

- AC-014-1: Given a new provider is added later, when it implements the messaging provider behavior/contract, then scheduler/run code does not change.
- AC-014-2: Given provider-specific capabilities differ, when Foreman renders a message, then unsupported rich features degrade to safe plain text instead of failing delivery; Telegram/Slack buttons and interactive actions are not required for v1.

## 7. Dependency Map

- REQ-002 depends on REQ-001 and REQ-005.
- REQ-003 depends on REQ-001, REQ-005, REQ-009, and REQ-010.
- REQ-004 depends on REQ-001 and Slack source verification; current evidence says Slack is planned-only, so TRD may implement the webhook adapter as new work.
- REQ-005 depends on workflow manifest notification settings, persisted Project configuration, and `:foreman_server, :messaging` application defaults.
- REQ-006 depends on REQ-001, REQ-002, REQ-005, and worker terminal/artifact capture for refine/collab URL output.
- REQ-007 depends on REQ-001, REQ-002, `Recovery.do_detect/1` stale-run detection, and `RunExecutor.emit_phase_failure/4` / `emit_run_failure/2` failure events.
- REQ-008 depends on REQ-001 and the event-sourced notification attempt/result contract projected through `ProjectionStore`.
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

Foreman mode auto-applied safe resolutions; no unresolved decision markers remain.

1. **Slack source of truth resolved.** Repository search found no runtime Slack implementation; Slack is planned-only, so v1 implements a new incoming-webhook provider unless TRD verification finds newer source.
2. **Send-only scope resolved.** v1 is outbound notification delivery only; inbound chat replies and command execution are out of scope.
3. **Notification spam bounded.** Dedupe defaults to 5 minutes by correlation id; noisy run updates are separately opt-in/rate-limited.
4. **Provider downtime isolated.** Run transitions enqueue locally within 250 ms and provider I/O happens asynchronously.
5. **Safe-field policy defined.** Chat rendering includes identifiers, severity, status, action summary, public URL/expiry, and redacted failure reason; prompts, env, artifacts, tokens, private URL secrets, and full descriptions are excluded by default.
6. **Collab URL source defined.** v1 listens to structured phase artifact/terminal output containing `Local:`, `Public:`, or `URL:` refine/collab links and emits a typed notification event.
7. **Stall source defined.** v1 uses `Recovery.do_detect/1` stale-run detection based on `ProjectionStore.list_runs/0`, `last_event_at`, and `:run_stale_after_ms` defaulting to 5 minutes.
8. **Delivery-state source defined.** Notification attempts/results are event-sourced, projected through `ProjectionStore`, and mirrored to telemetry/logs.

## 9. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 5 | Core providers, triggers, safety, docs, tests, source-of-truth defaults, and operator surfaces covered. |
| Testability | 5 | ACs now pin adapter payloads, stale/failure trigger sources, delivery-state storage, redaction, and test-delivery behavior. |
| Clarity | 4 | Former ambiguity markers are resolved with explicit v1 defaults and source citations; TRD still must map exact code modules. |
| Feasibility | 4 | Fits existing Elixir/Phoenix/OTP architecture and external provider APIs. |
| Overall | 4.4 | READY; suitable for TRD creation with source-verification follow-through. |

Gate decision: **READY — proceed to TRD creation**. The TRD must verify the named source contracts before implementation and must not reintroduce unresolved messaging behavior.

## 10. Suggested Next Step

Run:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-cfb5fec3-telegram-slack-messaging.md
```


## 11. Changelog

### 1.0.1 — 2026-09-04

- Auto-applied 18 Foreman-mode refinement findings.
- Resolved all prior clarification markers with source-backed v1 defaults.
- Clarified Slack as planned-only/currently unimplemented, v1 as send-only outbound messaging, one provider per destination, 5-minute default dedupe, 250 ms enqueue budget, event-sourced delivery state, safe chat fields, v1 event classes, and CLI/API test-delivery requirement.
- Added source evidence for stale-run detection, failure emission, operator inbox topic, and refine/collab URL motivation.
- Re-scored readiness from 3.8 to 4.4 and changed gate decision from CONCERNS to READY.
