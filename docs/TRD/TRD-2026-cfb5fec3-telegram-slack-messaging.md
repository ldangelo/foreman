---
document_id: TRD-2026-cfb5fec3
label: trd-telegram-slack-messaging
version: 1.0.1
status: Draft
date: 2026-09-04
prd_reference: docs/PRD/PRD-2026-cfb5fec3-telegram-slack-messaging.md
prd_label: prd-telegram-slack-messaging
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 36
design_readiness_score: 4.6
readiness_score: 4.6
total_tasks: 40
kind: trd
---

# TRD: Telegram and Slack Messaging Integration

Foreman task title read from `FOREMAN_TASK_TITLE`: **Integrate Telegram Slack messaging**.

## 1. Executive Summary

This TRD turns `PRD-2026-cfb5fec3` into a source-verified plan for outbound operator messaging in `packages/foreman_server`. v1 is send-only: Foreman emits safe, provider-neutral notifications for collab URLs, operator action, stalls, failures, and optional run updates; a supervised async delivery pipeline sends them to exactly one configured provider per destination: Telegram bot or Slack incoming webhook.

The PRD subject matches the Foreman task title. PRD readiness score is 4.4, so generation proceeds. MCP enhancement: skipped (no MCP tools detected).

Refinement pass v1.0.1 source-verified the existing server/CLI surfaces, closed one missing AC trace for unsupported-provider behavior, and tightened dispatcher/config/operator-surface implementation notes without changing scope or task count.

## 2. Source Verification Notes

- No runtime Slack or Telegram adapter exists in source; existing Slack/Telegram mentions identify a planned, unbuilt channel in `docs/PRD/PRD-2026-d306444f-phase-commit-control.md`.
- `ForemanServer.Recovery.do_detect/1` scans `ProjectionStore.list_runs/0`, filters non-terminal runs, reads `last_event_at`, and defaults `:run_stale_after_ms` to five minutes; messaging must observe/extend this path, not add a second stall detector.
- `ForemanServer.Workflow.RunExecutor.emit_phase_failure/4` dispatches `phase.fail`, then delegates to `emit_run_failure/2`, which treats `{:run_terminal, _}` as idempotent success and propagates other dispatch failures. Failure notification hooks must preserve that total handling.
- `ProjectionStore.run/1` and `ProjectionStore.phases_for_run/1` are bounded run-detail read surfaces. MCP `foreman_run_get` returns the raw run projection, and `foreman_run_status` builds a `RunStatus` DTO from those two reads; notification state must extend both read paths without weakening required identity/terminal checks.
- `ProjectionStore.subscribe/0` broadcasts `{:projection_event, event}` after `apply_events/1`/rebuild. The dispatcher can subscribe to this live event stream, but tests must pin no duplicate sends during rebuild/replay.
- `EventCodec` derives its registry from `lib/foreman_server/events/*.ex`; adding event structs registers them, but replay tests must pin strict decoding and unknown-key rejection.
- `ProjectUpdated` currently enforces only `project_id` and `task_provider`, while `ProjectionStore.apply_event_by_type/3` reads optional `:config` into the project projection. Messaging project config should use that config path and update the event struct plus aggregate tests if strict project-update commands persist config.
- `PhaseSpec` whitelists known phase keys and drops unrecognized keys. Workflow-level `notifications:` settings must be normalized at the workflow snapshot/catalog boundary rather than hidden in arbitrary phase maps.
- The Go CLI currently exposes `foreman run get <id>` against `/api/runs/:id`; there is no `run status` or messaging command yet. Any test-delivery CLI addition must be verified against `packages/foreman_cli/cmd/foreman/*.go` or a fresh `go build ./cmd/foreman`.
- `JidoSignalTopics.foreman_inbox/0` documents `com.foreman.inbox.*` as a human-facing agent-to-operator bus; messaging is an additional outbound delivery target, not a replacement for inbox/webhook ingest.

## 3. Architecture Decision

### 3.1 Alternatives Considered

#### Option A — Direct provider calls from lifecycle code (Rejected)

- Pros: smallest initial diff.
- Cons: blocks lifecycle code on provider I/O, leaks provider concerns into run/recovery modules, duplicates redaction/dedupe.
- Risk: high; provider downtime can contaminate run state.

#### Option B — Reuse SharedInbox as the outbound queue (Rejected)

- Pros: reuses existing inbox events/projections.
- Cons: inbox lacks provider, destination, retry, dedupe window, and delivery-attempt state.
- Risk: medium-high; operators cannot distinguish skipped, failed, and unseen delivery.

#### Option C — Event-sourced notification pipeline with provider adapters (Chosen)

Add `ForemanServer.Messaging` as the enqueue boundary. Triggers append typed notification events quickly. A supervised dispatcher sends asynchronously through Telegram/Slack adapters. Attempts/results are event-sourced and projected into run detail.

- Pros: matches Foreman's event/projection model; keeps provider I/O out of run transitions; provides one config/redaction/dedupe boundary; future providers implement one behavior.
- Cons: more modules/events than direct calls; requires projection and docs updates.
- Risk: low-medium; mitigated by pure contract tests and mocked HTTP clients.

Foreman mode: auto-selected Option C (event-sourced notification pipeline with provider adapters).

### 3.2 Chosen Architecture

| Area | Module/path | Responsibility |
|---|---|---|
| API | `lib/foreman_server/messaging.ex` | Public enqueue facade used by run/recovery/operator code. Returns fast `{:ok, notification_id}` or typed errors. |
| DTOs | `messaging/notification.ex`, `destination.ex`, `config.ex`, `delivery_result.ex` | Provider-neutral structs and validators. Unknown keys rejected. |
| Aggregate | `aggregates/notification.ex` | Event-sourced dedupe/attempt lifecycle on `notification:<correlation_id>`. |
| Events | `notification_enqueued/suppressed/delivery_attempted/delivery_succeeded/delivery_failed.ex` | Durable notification lifecycle source of truth. |
| Dispatcher | `messaging/dispatcher.ex` | Supervised `ProjectionStore.subscribe/0` consumer for enqueue events; dispatches provider I/O after local enqueue and ignores replay/rebuild duplicates by notification id/attempt id. |
| Providers | `messaging/provider.ex`, `providers/telegram.ex`, `providers/slack.ex` | Behavior plus HTTP adapters; no network in tests. |
| Rendering | `messaging/renderer.ex`, `messaging/redactor.ex` | Safe-field rendering and secret/private URL redaction. |
| Config | `messaging/config_resolver.ex` | Workflow `notifications:` → project config → `:foreman_server, :messaging`; disabled by default. |
| Triggers | focused trigger functions/modules | Collab URL, action-needed, stall, failure, run-update enqueue calls. |
| Projection | `projection_store.ex` | Fold notification events into per-run delivery state. |
| Operator surfaces | API/MCP/CLI/docs | Failed critical notifications in run reads plus a source-verified test-delivery operation. |

### 3.3 Data Flow

```
Run/recovery/operator trigger
  -> Messaging.notify(%Notification{})       # validation + config <= 250 ms
  -> command notification.enqueue
  -> Notification aggregate
       - validates event class/provider/destination
       - suppresses disabled classes
       - dedupes correlation ids in 300_000 ms default window
       - appends NotificationEnqueued/Suppressed
  -> Messaging.Dispatcher consumes enqueued events
  -> Renderer builds safe text only
  -> Provider adapter sends bounded HTTP request
  -> notification.delivery_succeeded | notification.delivery_failed
  -> ProjectionStore folds state into run detail
  -> API/MCP/CLI/docs expose delivery status/failures
```

### 3.4 Provider Contracts

- Telegram: `POST https://api.telegram.org/bot<token>/sendMessage`; JSON body contains `chat_id`, safe plain text, and no raw token in logs/errors.
- Slack: incoming webhook `POST <webhook_url>`; JSON body contains safe `text`; webhook URL is redacted everywhere.
- Provider behavior returns only typed results: `{:ok, %DeliveryResult{}}` or `{:error, %DeliveryResult{retryable?: boolean}}`.

### 3.5 Config Shape

Recommended defaults:

```elixir
config :foreman_server, :messaging,
  enabled: false,
  provider: :telegram,
  event_classes: [:collab_url, :action_needed, :stall, :failure],
  dedupe_window_ms: 300_000,
  run_update_rate_limit_ms: 300_000,
  telegram: [token: {:system, "FOREMAN_TELEGRAM_BOT_TOKEN"}, chat_id: {:system, "FOREMAN_TELEGRAM_CHAT_ID"}],
  slack: [webhook_url: {:system, "FOREMAN_SLACK_WEBHOOK_URL"}]
```

Workflow manifests may declare `notifications:`. Project config may carry the same normalized keys. Resolution order is workflow, project, app defaults. Missing/malformed selected provider config returns a typed validation error; it never falls back to another destination.

## 4. Reused Capabilities

No foundational TRD capabilities were registered by `trd-graph-cli capabilities docs/TRD --json`; no cross-TRD dependency is available.

## Master Task List

### PR 1: Messaging contract, config, and notification events

**Shippable State:** Operators can enable messaging configuration and Foreman can accept provider-neutral notification requests that are validated, deduped, projected, and visible in run detail without sending external chat messages yet.

- [ ] **TRD-001** — Add provider-neutral messaging DTOs and validation helpers (4h) [satisfies REQ-001] [satisfies REQ-009] [satisfies REQ-014]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-009-2, AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given a notification map contains recipient, severity, subject, body, optional URL, correlation id, and metadata, when normalized, then a typed struct is returned.
    - Given unknown or malformed keys are provided, when validation runs, then it returns a typed error and drops no known data silently.
    - Given an unsupported provider is configured, when the notification boundary resolves delivery, then a typed `unsupported_provider` error is recorded/logged without crashing the lifecycle caller.

- [ ] **TRD-001-TEST** — Test DTO validation, unknown-key rejection, unsupported-provider errors, and safe-field allowlist (3h) [verifies TRD-001] [satisfies REQ-001] [satisfies REQ-009] [satisfies REQ-014] [depends: TRD-001]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-009-2, AC-014-1
  - Implementation AC checklist:
    - Given valid and invalid notification maps, when tests run, then valid structs pass and invalid fields produce typed errors.
    - Given an unsupported provider atom/string is configured, when tests exercise the boundary, then the result is a typed config error and the caller process stays alive.
    - Given raw prompts/env/artifacts/full descriptions are supplied in metadata, when rendering allowlist tests run, then those fields are absent by default.

- [ ] **TRD-002** — Add messaging config resolver for workflow/project/app defaults (5h) [satisfies REQ-005] [satisfies REQ-011]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given workflow notifications are present, when config resolves, then workflow settings override project and app defaults.
    - Given messaging is disabled or an event class is disabled, when notification is evaluated, then provider delivery is suppressed with normal run behavior unchanged.
    - Given a destination is malformed, when config resolves, then no alternate destination is selected.

- [ ] **TRD-002-TEST** — Test config precedence, opt-out classes, and malformed destination errors (4h) [verifies TRD-002] [satisfies REQ-005] [satisfies REQ-011] [depends: TRD-002]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given conflicting workflow/project/app config, when tests run, then precedence is deterministic.
    - Given disabled classes include `run_update`, when run updates emit, then no provider call is attempted.

- [ ] **TRD-003** — Add notification aggregate commands/events for enqueue, suppress, attempt, success, and failure (6h) [satisfies REQ-002] [satisfies REQ-008] [satisfies REQ-010]
  - Validates PRD ACs: AC-002-2, AC-002-3, AC-008-1, AC-008-2, AC-010-2
  - Implementation AC checklist:
    - Given a notification correlation id is new, when enqueue dispatches, then `NotificationEnqueued` is appended.
    - Given the same correlation id repeats inside the dedupe window, when enqueue dispatches, then a duplicate skip/suppression event is recorded.
    - Given delivery succeeds or fails, when result commands dispatch, then provider, destination ref, correlation id, timestamp, status, and reason are recorded.

- [ ] **TRD-003-TEST** — Test notification aggregate state transitions, dedupe, and EventCodec replay (5h) [verifies TRD-003] [satisfies REQ-002] [satisfies REQ-008] [satisfies REQ-010] [depends: TRD-003]
  - Validates PRD ACs: AC-002-3, AC-008-1, AC-008-2, AC-010-2
  - Implementation AC checklist:
    - Given duplicate enqueue commands share correlation id and window, when tests run, then exactly one delivery-eligible event exists.
    - Given notification events are replayed through EventCodec, when projections rebuild, then strict decoding succeeds with no unknown keys.

- [ ] **TRD-004** — Project notification delivery state into `ProjectionStore.run/1` and run detail DTOs (5h) [satisfies REQ-008] [satisfies REQ-010]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-010-3
  - Implementation AC checklist:
    - Given notification lifecycle events are applied, when `ProjectionStore.run(run_id)` is read, then latest delivery state is present.
    - Given a critical notification fails, when run status/API/MCP detail is read, then failed notification metadata is visible without raw secrets.

- [ ] **TRD-004-TEST** — Test notification projection in run detail and duplicate skip visibility (4h) [verifies TRD-004] [satisfies REQ-008] [satisfies REQ-010] [depends: TRD-004]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-010-3
  - Implementation AC checklist:
    - Given attempt/success/failure events, when projection tests read a run, then status and failure reason match events.
    - Given a duplicate is skipped, when projection tests read notification state, then skipped status is attributable.

### PR 2: Async dispatcher, redaction, and provider adapters

**Shippable State:** Operators can configure Telegram or Slack test delivery and receive safe outbound messages while run progression remains independent of provider availability.

- [ ] **TRD-005** — Add supervised async messaging dispatcher with bounded enqueue budget (5h) [satisfies REQ-010]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3
  - Implementation AC checklist:
    - Given a lifecycle event triggers messaging, when provider I/O is slow, then the lifecycle caller returns after local enqueue without waiting on HTTP.
    - Given `ProjectionStore.subscribe/0` delivers live or rebuild projection events, when the dispatcher sees an already-attempted notification id, then no duplicate provider call occurs.
    - Given provider delivery fails, when the run is otherwise healthy, then the run status does not become failed solely due to messaging.

- [ ] **TRD-005-TEST** — Test dispatcher non-blocking behavior and failed-delivery isolation (4h) [verifies TRD-005] [satisfies REQ-010] [depends: TRD-005]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3
  - Implementation AC checklist:
    - Given a fake slow provider, when enqueue tests run, then the caller stays within the configured local budget.
    - Given a permanent provider failure, when dispatcher tests complete, then run state remains unchanged and delivery failure is projected.

- [ ] **TRD-006** — Add safe renderer and redactor for message body, logs, telemetry, and provider responses (5h) [satisfies REQ-009] [satisfies REQ-014]
  - Validates PRD ACs: AC-009-1, AC-009-2, AC-009-3, AC-014-2
  - Implementation AC checklist:
    - Given notification metadata includes secrets, env, raw artifacts, prompts, or private URL tokens, when rendering/logging occurs, then output excludes or redacts them.
    - Given a provider supports no rich features, when rendering happens, then safe plain text is produced.

- [ ] **TRD-006-TEST** — Test redaction for tokens, webhook URLs, chat ids, private links, and unsafe metadata (4h) [verifies TRD-006] [satisfies REQ-009] [satisfies REQ-014] [depends: TRD-006]
  - Validates PRD ACs: AC-009-1, AC-009-2, AC-009-3, AC-014-2
  - Implementation AC checklist:
    - Given Telegram tokens and Slack webhook URLs appear in inputs/errors, when tests inspect logs/results, then raw values are absent.
    - Given full task descriptions or prompt content are present, when renderer tests run, then only safe summary fields are emitted.

- [ ] **TRD-007** — Implement Telegram provider adapter behind messaging behavior (5h) [satisfies REQ-003] [satisfies REQ-014] [depends: TRD-005] [depends: TRD-006]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given valid token/chat id config, when Telegram sends, then adapter builds a `sendMessage` request with safe text and bounded timeout.
    - Given token/chat id is missing, when selected, then a typed config error is returned before network delivery.
    - Given Telegram returns error/rate-limit/timeout, when delivery completes, then retry eligibility and typed reason are recorded.

- [ ] **TRD-007-TEST** — Test Telegram endpoint, method, payload, timeout, rate-limit, and redaction without network (4h) [verifies TRD-007] [satisfies REQ-003] [satisfies REQ-009] [satisfies REQ-013] [depends: TRD-007]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-009-1, AC-013-1
  - Implementation AC checklist:
    - Given a fake HTTP client, when Telegram adapter tests run, then endpoint/method/payload/timeout match contract.
    - Given Telegram failures include sensitive request data, when results/logs are inspected, then secrets are redacted.

- [ ] **TRD-008** — Implement Slack incoming-webhook provider adapter behind same behavior (4h) [satisfies REQ-004] [satisfies REQ-014] [depends: TRD-005] [depends: TRD-006]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given Slack is selected, when notification sends, then only Slack webhook adapter is called.
    - Given both providers are configured and routing selects Slack, when delivery occurs, then Telegram is not called.

- [ ] **TRD-008-TEST** — Test Slack webhook method, payload, timeout, provider routing, and redaction without network (4h) [verifies TRD-008] [satisfies REQ-004] [satisfies REQ-009] [satisfies REQ-013] [depends: TRD-008]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-009-1, AC-013-2
  - Implementation AC checklist:
    - Given a fake HTTP client, when Slack adapter tests run, then endpoint/method/payload/timeout match incoming-webhook contract.
    - Given both providers are configured, when Slack is selected, then tests assert no Telegram call occurs.

### PR 3: Lifecycle notification triggers

**Shippable State:** Operators receive configured notifications for action-needed events, collab URLs, stalls, and failures, with dedupe/rate limits preventing repeated noisy messages.

- [ ] **TRD-009** — Emit action-needed operator notifications from existing operator question/inbox paths (4h) [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-003] [depends: TRD-005]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given a task requires operator attention, when the existing operator question path dispatches, then messaging enqueues one `action_needed` notification with task/run/workflow context.
    - Given messaging or `action_needed` is disabled, when the same event occurs, then no provider call is attempted.

- [ ] **TRD-009-TEST** — Test action-needed trigger and disabled-class suppression (3h) [verifies TRD-009] [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-009]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given operator-question events occur, when tests run, then exactly one `action_needed` notification is enqueued per correlation id.
    - Given class is disabled, when trigger tests run, then provider delivery is suppressed.

- [ ] **TRD-010** — Detect collab/public URLs from structured artifacts and safe terminal patterns (5h) [satisfies REQ-006] [satisfies REQ-009] [depends: TRD-003]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-009-2, AC-009-3
  - Implementation AC checklist:
    - Given a phase artifact or output contains `Local:`, `Public:`, or `URL:` for a refine/collab session, when the phase completes, then a structured `collab_url` notification is enqueued with run/task/phase and validity details when present.
    - Given no URL is produced for a human-refinement phase, when phase output is inspected, then an action-needed/failure notification is sent without inventing a URL.

- [ ] **TRD-010-TEST** — Test collab URL extraction, non-invention, and private-token redaction (4h) [verifies TRD-010] [satisfies REQ-006] [satisfies REQ-009] [depends: TRD-010]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-009-2, AC-009-3
  - Implementation AC checklist:
    - Given sample artifact/stdout lines contain supported URL labels, when tests run, then the expected URL notification is emitted.
    - Given URL tokens are private or absent, when tests run, then output redacts tokens or emits no invented URL.

- [ ] **TRD-011** — Emit stall alerts from `Recovery.do_detect/1` stale-run path (4h) [satisfies REQ-007] [satisfies REQ-002] [depends: TRD-003] [depends: TRD-005]
  - Validates PRD ACs: AC-007-1, AC-002-1, AC-002-3
  - Implementation AC checklist:
    - Given `Recovery.do_detect/1` classifies a run stale, when recovery event dispatch succeeds, then exactly one `stall` notification is enqueued with suggested next action.
    - Given repeated scans occur inside the dedupe window, when notifications evaluate, then no duplicate provider call occurs.

- [ ] **TRD-011-TEST** — Test stale-run trigger from ProjectionStore activity and dedupe (3h) [verifies TRD-011] [satisfies REQ-007] [satisfies REQ-002] [depends: TRD-011]
  - Validates PRD ACs: AC-007-1, AC-002-3
  - Implementation AC checklist:
    - Given active runs cross stale threshold, when recovery tests run, then one stall notification is enqueued.
    - Given scans repeat within 300 seconds, when tests run, then duplicate notification is skipped/recorded.

- [ ] **TRD-012** — Emit failure/cancelled notifications from phase/run terminal transitions (4h) [satisfies REQ-007] [satisfies REQ-010] [depends: TRD-003] [depends: TRD-005]
  - Validates PRD ACs: AC-007-2, AC-007-3, AC-010-2, AC-010-3
  - Implementation AC checklist:
    - Given `emit_phase_failure/4` or `emit_run_failure/2` records terminal failure/cancelled state, when transition succeeds, then one `failure` notification is enqueued per run terminal transition.
    - Given provider delivery fails, when failure notification fails, then no recursive provider-error alert is emitted.

- [ ] **TRD-012-TEST** — Test phase/run failure trigger, cancellation trigger, and recursion guard (4h) [verifies TRD-012] [satisfies REQ-007] [satisfies REQ-010] [depends: TRD-012]
  - Validates PRD ACs: AC-007-2, AC-007-3, AC-010-2, AC-010-3
  - Implementation AC checklist:
    - Given phase failure and run cancellation events, when tests run, then exactly one failure notification exists for each terminal transition.
    - Given the provider returns an error, when dispatcher tests run, then no provider-error notification is recursively enqueued.

- [ ] **TRD-013** — Add optional run-update trigger class with separate rate limit (3h) [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-003]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given `run_update` is enabled, when configured lifecycle updates occur, then rate-limited summary notifications are enqueued.
    - Given `run_update` is disabled by default, when normal runs progress, then no noisy update provider calls occur.

- [ ] **TRD-013-TEST** — Test run-update opt-in and class-specific rate limiting (3h) [verifies TRD-013] [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-013]
  - Validates PRD ACs: AC-002-2, AC-002-3, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given update events happen rapidly, when rate-limit tests run, then only allowed messages are delivery-eligible.
    - Given update class is not configured, when trigger tests run, then delivery is suppressed.

### PR 4: Operator surfaces and test-delivery command

**Shippable State:** Operators can inspect delivery status/failures through run detail surfaces and run a test-delivery operation before trusting Telegram or Slack setup.

- [ ] **TRD-014** — Expose notification delivery state in API and MCP run-status/read surfaces (4h) [satisfies REQ-008] [satisfies REQ-010] [depends: TRD-004]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-010-3
  - Implementation AC checklist:
    - Given a run has notification attempts, when API/MCP run status is read, then delivery summaries and failed critical notifications are present.
    - Given no notification attempts exist, when run detail is read, then response distinguishes absent from malformed state without errors.

- [ ] **TRD-014-TEST** — Test API/MCP run detail includes delivery state without leaking secrets (3h) [verifies TRD-014] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-010] [depends: TRD-014]
  - Validates PRD ACs: AC-008-1, AC-009-1, AC-009-3, AC-010-3
  - Implementation AC checklist:
    - Given delivery failures include provider details, when API/MCP tests inspect JSON, then redacted status is present and raw secrets are absent.

- [ ] **TRD-015** — Add operator test-delivery operation through CLI or API using existing command policy (5h) [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-012]
  - Validates PRD ACs: AC-003-1, AC-003-3, AC-004-1, AC-012-1, AC-012-2
  - Implementation AC checklist:
    - Given Telegram/Slack config is valid, when operator runs test delivery, then a safe test message is sent and result is reported.
    - Given config is invalid, when operator runs test delivery, then typed auth/malformed/unsupported-provider errors are returned.

- [ ] **TRD-015-TEST** — Test test-delivery success/failure envelopes and CLI/API error mapping (4h) [verifies TRD-015] [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-012] [depends: TRD-015]
  - Validates PRD ACs: AC-003-1, AC-003-3, AC-004-1, AC-012-1, AC-012-2
  - Implementation AC checklist:
    - Given fake providers return success, auth failure, malformed destination, network error, rate limit, and unsupported provider, when tests run, then operator-facing envelopes distinguish each case.

- [ ] **TRD-016** — Add telemetry/log events for notification enqueue, suppress, attempt, success, and failure (3h) [satisfies REQ-008] [satisfies REQ-009]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-009-1, AC-009-3
  - Implementation AC checklist:
    - Given notification lifecycle changes, when telemetry is emitted, then provider, event class, status, and retryable flag are present.
    - Given secrets exist in config/provider responses, when logs/telemetry are inspected, then raw values are redacted.

- [ ] **TRD-016-TEST** — Test telemetry/log payloads and redaction (3h) [verifies TRD-016] [satisfies REQ-008] [satisfies REQ-009] [depends: TRD-016]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-009-1, AC-009-3
  - Implementation AC checklist:
    - Given notification lifecycle tests attach telemetry handlers, when events fire, then expected fields exist and raw secrets do not.

### PR 5: Documentation and configuration hardening

**Shippable State:** Operators can follow documented Telegram/Slack setup, configure event classes safely, diagnose delivery failures, and understand security limits.

- [ ] **TRD-017** — Update living docs for messaging setup, config, event classes, and troubleshooting (5h) [satisfies REQ-012] [satisfies REQ-005] [satisfies REQ-011]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-005-1, AC-005-2, AC-011-1
  - Implementation AC checklist:
    - Given docs are updated, when an operator wants Telegram, then bot creation, token wiring, chat id discovery, provider selection, and test delivery are documented.
    - Given delivery fails, when troubleshooting docs are read, then auth, malformed destination, network, rate limit, disabled messaging, and unsupported provider are distinguished.

- [ ] **TRD-017-TEST** — Validate docs references against implemented config keys and CLI/API syntax (2h) [verifies TRD-017] [satisfies REQ-012] [depends: TRD-017]
  - Validates PRD ACs: AC-012-1, AC-012-2
  - Implementation AC checklist:
    - Given docs mention commands/env/config keys, when verification runs, then every identifier exists in source or is explicitly marked planned historical context.

- [ ] **TRD-018** — Wire secrets provider/env mapping for Telegram token, chat id, and Slack webhook URL (4h) [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-009] [depends: TRD-002]
  - Validates PRD ACs: AC-003-3, AC-004-1, AC-009-1, AC-009-3
  - Implementation AC checklist:
    - Given env-backed provider credentials are configured, when config loads, then values are available to adapters without being logged.
    - Given required selected-provider secrets are missing, when delivery/test-delivery runs, then a typed configuration error occurs before network calls.

- [ ] **TRD-018-TEST** — Test secret loading, missing-secret errors, and redaction (3h) [verifies TRD-018] [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-009] [depends: TRD-018]
  - Validates PRD ACs: AC-003-3, AC-004-1, AC-009-1, AC-009-3
  - Implementation AC checklist:
    - Given env values exist or are absent, when config tests run, then adapters receive only resolved valid credentials or typed missing-secret errors.

- [ ] **TRD-019** — Add architecture/developer docs for provider behavior and future provider extension (3h) [satisfies REQ-014] [satisfies REQ-001]
  - Validates PRD ACs: AC-014-1, AC-014-2, AC-001-1, AC-001-2
  - Implementation AC checklist:
    - Given a maintainer adds a provider later, when reading developer docs, then behavior callbacks, result types, redaction, and test expectations are clear.

- [ ] **TRD-019-TEST** — Add architecture test preventing provider modules from being called directly by run/recovery code (2h) [verifies TRD-019] [satisfies REQ-001] [satisfies REQ-014] [depends: TRD-019]
  - Validates PRD ACs: AC-001-2, AC-014-1
  - Implementation AC checklist:
    - Given source is scanned in tests, when run/recovery modules are inspected, then they reference `Messaging` boundary and not provider adapters directly.

### PR 6: End-to-end contract validation

**Shippable State:** A configured project can run a representative workflow and emit deduped, redacted Telegram/Slack notifications for collab URL, stall, failure, and action-needed paths with all tests passing.

- [ ] **TRD-020** — Add end-to-end notification trigger tests over representative run/projection flow (6h) [satisfies REQ-002] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-010] [satisfies REQ-013] [depends: TRD-009] [depends: TRD-010] [depends: TRD-011] [depends: TRD-012] [depends: TRD-014]
  - Validates PRD ACs: AC-002-1, AC-006-1, AC-007-1, AC-007-2, AC-008-1, AC-010-1, AC-013-3
  - Implementation AC checklist:
    - Given configured fake providers and representative run events, when E2E tests run, then collab URL, stall, failure, and action-needed notifications are enqueued and projected exactly once.
    - Given provider I/O fails, when E2E flow completes, then core run terminal status remains correct and delivery failure is visible.

- [ ] **TRD-020-TEST** — Run focused ExUnit suites, format, and static documentation checks (3h) [verifies TRD-020] [satisfies REQ-012] [satisfies REQ-013] [depends: TRD-020]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-013-1, AC-013-2, AC-013-3
  - Implementation AC checklist:
    - Given implementation is complete, when focused tests and `mix format --check-formatted` run, then all pass.
    - Given docs/config identifiers changed, when documentation gate checks run, then required docs are updated or explicitly justified.

## Sprint Planning

## Sprint 1: Core event-sourced messaging foundation

PR 1 and PR 2. Outcome: validated notification contract, config, projection, async dispatcher, renderer/redactor, Telegram and Slack provider adapters.

## Sprint 2: Trigger integration and operator surfaces

PR 3 and PR 4. Outcome: action-needed, collab URL, stall, failure, and optional run-update notifications plus run-detail/test-delivery surfaces.

## Sprint 3: Docs and end-to-end hardening

PR 5 and PR 6. Outcome: operator docs, secret wiring, future-provider guidance, and E2E proof.

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Messaging provider abstraction | TRD-001, TRD-019 | TRD-001-TEST, TRD-019-TEST |
| REQ-002 | Operator-facing notifications | TRD-003, TRD-009, TRD-011, TRD-013, TRD-020 | TRD-003-TEST, TRD-009-TEST, TRD-011-TEST, TRD-013-TEST, TRD-020-TEST |
| REQ-003 | Telegram bot delivery | TRD-007, TRD-015, TRD-018 | TRD-007-TEST, TRD-015-TEST, TRD-018-TEST |
| REQ-004 | Slack delivery support | TRD-008, TRD-015, TRD-018 | TRD-008-TEST, TRD-015-TEST, TRD-018-TEST |
| REQ-005 | Safe channel configuration | TRD-002, TRD-017 | TRD-002-TEST, TRD-017-TEST |
| REQ-006 | Collab URL notifications | TRD-010, TRD-020 | TRD-010-TEST, TRD-020-TEST |
| REQ-007 | Stall/failure/error alerts | TRD-011, TRD-012, TRD-020 | TRD-011-TEST, TRD-012-TEST, TRD-020-TEST |
| REQ-008 | Delivery state/failures | TRD-003, TRD-004, TRD-014, TRD-016, TRD-020 | TRD-003-TEST, TRD-004-TEST, TRD-014-TEST, TRD-016-TEST, TRD-020-TEST |
| REQ-009 | Secret/content protection | TRD-001, TRD-006, TRD-010, TRD-016, TRD-018 | TRD-001-TEST, TRD-006-TEST, TRD-010-TEST, TRD-016-TEST, TRD-018-TEST |
| REQ-010 | Non-blocking delivery | TRD-003, TRD-004, TRD-005, TRD-012, TRD-014, TRD-020 | TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-012-TEST, TRD-014-TEST, TRD-020-TEST |
| REQ-011 | Operator controls/opt-out | TRD-002, TRD-009, TRD-013, TRD-017 | TRD-002-TEST, TRD-009-TEST, TRD-013-TEST, TRD-017-TEST |
| REQ-012 | Setup/troubleshooting docs | TRD-015, TRD-017, TRD-020-TEST | TRD-015-TEST, TRD-017-TEST, TRD-020-TEST |
| REQ-013 | Provider/trigger tests | TRD-007-TEST, TRD-008-TEST, TRD-020, TRD-020-TEST | TRD-007-TEST, TRD-008-TEST, TRD-020-TEST |
| REQ-014 | Future provider extensibility | TRD-001, TRD-006, TRD-007, TRD-008, TRD-019 | TRD-001-TEST, TRD-006-TEST, TRD-007-TEST, TRD-008-TEST, TRD-019-TEST |

Traceability check: 14 requirements covered, 0 uncovered, 0 orphaned annotations.

## 8. Adversarial Review

### Architecture Issues

1. **Workflow notification config could drift from PhaseSpec normalization.** Resolution: add a workflow-level notification normalizer and tests; do not hide config under phase maps.
2. **Project config event shape may reject persisted config on strict decode.** Resolution: source-verify `ProjectUpdated` payload handling during implementation and update the event struct/tests if config is now part of the persisted contract.
3. **Provider failure alerts can recurse.** Resolution: provider-error recording must be terminal for that notification and must not enqueue a provider-error notification class.

### Coverage Issues

1. **Slack is planned-only, not preserved runtime behavior.** Resolution: implement Slack incoming webhook as new provider while keeping a source-verification task/test expectation.
2. **Collab URL detection from terminal text can leak tokens.** Resolution: prefer structured artifacts, support only known labels, and pass every URL through redaction/safe-rendering before logs or chat.

### Dependency and Estimate Issues

1. **Triggers depend on core event/projection/dispatcher work.** Resolution: PR 3 depends on PR 1/2 and has no direct provider calls.
2. **End-to-end tests could be flaky if they use real provider I/O.** Resolution: use fake HTTP clients/providers for CI; manual test-delivery is operator-facing, not CI network dependency.

### Testability Issues

1. **“Non-blocking within 250 ms” needs deterministic proof.** Resolution: use fake slow provider and assert lifecycle caller returns before provider completion under a controlled clock/timeout.
2. **“Safe fields” can become subjective.** Resolution: renderer tests assert an explicit allowlist and denylist.

## 9. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4.6 | Components, events, providers, data flow, config, projections, CLI/API/MCP surfaces, and dispatcher subscription source are defined. |
| Task coverage | 4.8 | Every REQ and every PRD AC has implementation and test coverage; unsupported-provider AC now traced explicitly. |
| Dependency clarity | 4.5 | PR ordering is acyclic; trigger work waits for core/dispatcher and rebuild duplicate behavior is called out. |
| Estimate confidence | 4.4 | Tasks are under 8h and scoped to narrow modules; HTTP client/test-delivery CLI shape may affect estimates. |
| Overall | 4.6 | PASS |

Gate decision: **PASS — ready for implementation planning after approval**.

## 10. Validation Plan

- `cd packages/foreman_server && mix format --check-formatted`
- Focused ExUnit suites for messaging DTO/config/aggregate/projection/provider/trigger modules.
- API/MCP/CLI contract tests for delivery state and test-delivery output.
- Documentation gate: check `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md`; edit those whose operator-visible identifiers changed.
- `git diff --check`

## 11. Next Steps

After review/approval:

```bash
/ensemble-configure-team docs/TRD/TRD-2026-cfb5fec3-telegram-slack-messaging.md
/ensemble-implement-trd-beads docs/TRD/TRD-2026-cfb5fec3-telegram-slack-messaging.md
```

## 12. Changelog

### 1.0.1 — 2026-09-04

- Source-verified recovery, run failure, projection subscription, EventCodec, ProjectUpdated config, MCP run-status, and CLI run-get surfaces.
- Added explicit AC-001-3 coverage for unsupported-provider behavior.
- Tightened dispatcher requirements around `ProjectionStore.subscribe/0` rebuild/replay duplicate avoidance.
- Raised readiness score from 4.5 to 4.6 without changing scope or task count.
