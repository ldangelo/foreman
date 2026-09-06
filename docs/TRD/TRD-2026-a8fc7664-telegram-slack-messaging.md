---
document_id: TRD-2026-a8fc7664
label: trd-telegram-slack-messaging
version: 1.0.0
status: Draft
date: 2026-09-05
prd_reference: docs/PRD/PRD-2026-a8fc7664-telegram-slack-messaging.md
prd_label: prd-telegram-slack-messaging
scale_depth: STANDARD
total_requirements: 16
total_acceptance_criteria: 38
design_readiness_score: 4.6
readiness_score: 4.6
total_tasks: 36
kind: trd
---

# TRD: Telegram and Slack Messaging Integration

Foreman task title read from `FOREMAN_TASK_TITLE`: **Integrate Telegram Slack messaging**.

## 1. Executive Summary

This TRD converts `PRD-2026-a8fc7664` into a brownfield implementation plan for outbound, send-only Telegram bot and Slack incoming-webhook messaging. The PRD subject matches `FOREMAN_TASK_TITLE`. PRD readiness score is 4.5, so generation proceeds.

Current source already provides the core messaging boundary, DTO validation, config resolver, notification aggregate, lifecycle events, redaction helper, renderer, provider behavior, and notification projection. Remaining work is async durable provider delivery, real Telegram/Slack adapters, trigger wiring, operator test-delivery/read surfaces, docs, and end-to-end proof.

MCP enhancement: skipped (no MCP tools detected).

## 2. Source Verification Notes

- `ForemanServer.Messaging.notify/2` normalizes notifications, resolves config, adds enabled/dedupe fields, and dispatches `notification.enqueue` with a 250 ms timeout.
- `ForemanServer.Messaging.Notification` accepts only provider-neutral fields, allows providers `:telegram` and `:slack`, allows event classes `:collab_url`, `:action_needed`, `:stall`, `:failure`, `:run_update`, and `:test`, and drops unsafe metadata keys by allowlist.
- `ForemanServer.Messaging.ConfigResolver` resolves app/project/workflow messaging settings with workflow over project over app defaults; disabled is default; enabled destinations must validate as selected Telegram or Slack config.
- `ForemanServer.Aggregates.Notification` records enqueue, suppression, attempt, success, and failure events keyed by `notification:<correlation_id>` and dedupes repeated correlation ids inside the configured window.
- `ProjectionStore` folds notification lifecycle events into `run.notifications`, so run detail can expose latest delivery state.
- `ForemanServer.Messaging.Provider`, `DeliveryResult`, `Renderer`, and `Redactor` exist, but no `messaging/providers/telegram.ex`, `messaging/providers/slack.ex`, or dispatcher module exists.
- `Recovery.do_detect/1` and the newer `StallDetector`/`run.report_stall` flow are stall sources; notification hooks must observe existing stale/stall facts instead of adding another detector.
- `Workflow.RunExecutor.emit_phase_failure/4` and `emit_run_failure/2` are failure transition hooks; notification failures must never recurse into run failure.
- Go CLI currently has run/project/task surfaces, but no source-verified messaging test-delivery command.

## 3. Architecture Decision

### 3.1 Alternatives Considered

#### Option A — Direct provider calls from run/recovery code (Rejected)

- Pros: smallest immediate diff.
- Cons: blocks lifecycle code on HTTP, leaks provider details into scheduler/recovery/run modules, duplicates config/redaction/dedupe.
- Risk: high; provider outage could stall or contaminate healthy runs.

#### Option B — Use inbox/operator messages as the outbound queue (Rejected)

- Pros: reuses existing operator-facing concepts.
- Cons: inbox lacks provider routing, destination validation, attempt/result state, retry classification, dedupe windows, and provider contracts.
- Risk: medium-high; missed alerts would be hard to distinguish from disabled/suppressed/provider-failed delivery.

#### Option C — Event-sourced notification pipeline with provider adapters (Chosen)

Extend the existing `ForemanServer.Messaging` + `Aggregates.Notification` foundation. Triggers enqueue provider-neutral notifications quickly; a supervised durable dispatcher performs provider I/O through Telegram/Slack adapters; attempt/result events project into run read surfaces.

- Pros: best fit for Foreman's event/projection model; preserves non-blocking runs; one validation/redaction/dedupe boundary; future providers implement one behavior.
- Cons: requires dispatcher/retry/catch-up logic and surface/docs changes.
- Risk: low-medium; mitigated with fake provider/HTTP tests and restart/replay tests.

Foreman mode: auto-selected Option C (event-sourced notification pipeline with provider adapters).

### 3.2 Component Boundaries

| Area | Module/path | Responsibility |
|---|---|---|
| Boundary | `lib/foreman_server/messaging.ex` | Public fast enqueue API; never performs provider network I/O. |
| DTO/config | `messaging/notification.ex`, `config.ex`, `config_resolver.ex` | Provider-neutral validation, safe metadata, deterministic precedence, selected-provider destination validation. |
| Aggregate/events | `aggregates/notification.ex`, `events/notification_*` | Durable lifecycle source: enqueue/suppress/attempt/success/failure. |
| Dispatcher | new `messaging/dispatcher.ex` | Supervised durable delivery worker; consumes enqueued notifications, records attempts/results, catches up after restart, avoids replay duplicates. |
| Providers | new `messaging/providers/telegram.ex`, `messaging/providers/slack.ex` | HTTP adapters behind `Messaging.Provider`; return typed `DeliveryResult`. |
| Rendering/redaction | `messaging/renderer.ex`, `redactor.ex` | Safe text from allowlisted fields; redact tokens, webhook URLs, private URL credentials, and provider errors. |
| Triggers | focused hook modules/functions near run/recovery/inbox/artifact code | Emit `collab_url`, `action_needed`, `stall`, `failure`, and opt-in `run_update` notifications by correlation id. |
| Read surfaces | `ProjectionStore`, HTTP/MCP/Go CLI | Show latest per-run notification state and redacted failure/suppression reason. |
| Test delivery | new API/CLI operation | Resolve config, send `test` event, report status without requiring a workflow run. |

### 3.3 Data Flow

```text
run/recovery/operator trigger
  -> Messaging.notify(attrs, workflow_config/project_config)
  -> CommandRouter dispatch notification.enqueue <= 250 ms
  -> Notification aggregate appends Enqueued or Suppressed
  -> Messaging.Dispatcher claims enqueued notification durably
  -> Renderer/Redactor builds safe provider text
  -> Telegram/Slack adapter sends bounded HTTP request
  -> NotificationDeliveryAttempted/Succeeded/Failed events
  -> ProjectionStore folds run.notifications
  -> API/MCP/CLI/debug/docs expose redacted state
```

### 3.4 Provider Contracts

- Telegram: `POST https://api.telegram.org/bot<token>/sendMessage`; JSON includes `chat_id`, safe plain text, optional URL in text, and bounded timeout. Token/chat id are never logged raw.
- Slack: `POST <webhook_url>` incoming webhook; JSON includes safe `text`; webhook URL is redacted in errors/logs/telemetry.
- Provider callback returns only `{:ok, %DeliveryResult{status: :succeeded}}` or `{:error, %DeliveryResult{status: :failed, retryable?: boolean(), reason: redacted_reason}}`.
- Retry classes: auth/malformed destination = non-retryable; timeout/network/rate-limit/provider 5xx = retryable unless max policy exhausted.

### 3.5 Config Shape

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

Workflow/project config may use `notifications:` or `messaging:` with the same normalized keys. Unknown top-level keys are dropped only at the config boundary; malformed known keys return typed errors. Destination fallback across providers is forbidden.

## 4. Reused Capabilities

`trd-graph-cli capabilities docs/TRD --json` returned an empty registry and `overlap docs/TRD` reported no overlapping target files. No foundational cross-TRD dependency is available. Source reuse is direct: existing messaging DTO/config/aggregate/render/projection modules must be extended, not duplicated.

## Master Task List

### PR 1: Messaging foundation audit and durable delivery skeleton

**Shippable State:** Operators can enable messaging config and Foreman can accept, suppress, and project provider-neutral notification requests without sending external chat messages.

- [x] **TRD-001** — Verify and preserve provider-neutral notification DTO/boundary validation (2h) [satisfies REQ-001] [satisfies REQ-005] [satisfies REQ-016]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-005-1, AC-016-1
  - Implementation AC checklist:
    - Given valid provider-neutral attrs, when `Notification.normalize/1` runs, then only known fields enter the struct.
    - Given unknown fields or unsupported providers, when normalization runs, then typed errors are returned before enqueue.

- [x] **TRD-001-TEST** — Preserve DTO tests for known-field validation, unsupported providers, and metadata allowlist (2h) [verifies TRD-001] [satisfies REQ-001] [satisfies REQ-005] [satisfies REQ-016] [depends: TRD-001]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-005-1, AC-016-1
  - Implementation AC checklist:
    - Given unsafe metadata keys, when tests run, then they are absent from normalized metadata.
    - Given provider `irc`, when tests run, then typed rejection is asserted.

- [x] **TRD-002** — Verify and preserve messaging config resolver precedence and destination validation (2h) [satisfies REQ-002] [satisfies REQ-011]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-011-2
  - Implementation AC checklist:
    - Given workflow/project/app settings conflict, when config resolves, then workflow wins over project over app.
    - Given selected provider destination is malformed, when config resolves enabled messaging, then a provider-specific typed error is returned.

- [x] **TRD-002-TEST** — Preserve config tests for precedence, disabled default, string keys, and malformed destinations (3h) [verifies TRD-002] [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-002]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-011-2
  - Implementation AC checklist:
    - Given disabled config, when tests resolve config, then destination is not required and no provider call is possible.
    - Given Slack webhook URL is empty, when tests resolve config, then `:slack_destination` is returned.

- [x] **TRD-003** — Verify and preserve notification aggregate lifecycle events and dedupe (3h) [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-011]
  - Validates PRD ACs: AC-006-1, AC-006-3, AC-007-1, AC-007-2, AC-011-1
  - Implementation AC checklist:
    - Given a new correlation id, when enqueue dispatches, then `NotificationEnqueued` is appended.
    - Given a repeated correlation id inside the dedupe window, when enqueue dispatches, then `NotificationSuppressed` reason `duplicate` is appended.

- [x] **TRD-003-TEST** — Preserve aggregate tests for enqueue, suppression, attempt, success, failure, and replay shape (3h) [verifies TRD-003] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-011] [depends: TRD-003]
  - Validates PRD ACs: AC-006-3, AC-007-1, AC-007-2, AC-011-1
  - Implementation AC checklist:
    - Given aggregate events replay, when state folds, then status/attempt metadata match persisted events.
    - Given duplicate commands, when tests run, then only one delivery-eligible enqueue remains.

- [x] **TRD-004** — Verify and preserve notification projection into run detail (2h) [satisfies REQ-007] [satisfies REQ-013]
  - Validates PRD ACs: AC-007-1, AC-007-2, AC-013-1, AC-013-2
  - Implementation AC checklist:
    - Given notification lifecycle events include run id, when projected, then `ProjectionStore.run/1` includes `notifications` with status/reason.
    - Given suppression occurs, when projected, then suppression reason is distinguishable from provider failure.

- [x] **TRD-004-TEST** — Preserve projection tests for run notification status and redacted failure/suppression visibility (2h) [verifies TRD-004] [satisfies REQ-007] [satisfies REQ-013] [depends: TRD-004]
  - Validates PRD ACs: AC-007-1, AC-007-2, AC-013-1, AC-013-2
  - Implementation AC checklist:
    - Given failed delivery event, when run projection is read, then failure status/reason are visible.
    - Given no notifications exist, when run projection is read, then notifications is an empty list.

- [ ] **TRD-005** — Add durable supervised messaging dispatcher with restart catch-up and replay dedupe (6h) [satisfies REQ-006] [satisfies REQ-007] [depends: TRD-003] [depends: TRD-004]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-007-1
  - Implementation AC checklist:
    - Given provider I/O is slow, when `Messaging.notify/2` returns, then caller waits only for local enqueue within the 250 ms budget.
    - Given Foreman restarts after enqueue, when dispatcher starts, then unattempted enqueued notifications are claimed once and delivered or failed.
    - Given projection replay/rebuild emits old events, when dispatcher sees already-attempted notification ids, then no duplicate provider sends occur.

- [ ] **TRD-005-TEST** — Test dispatcher non-blocking, restart catch-up, replay dedupe, and failure isolation (5h) [verifies TRD-005] [satisfies REQ-006] [satisfies REQ-007] [depends: TRD-005]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-007-1
  - Implementation AC checklist:
    - Given a fake slow provider, when enqueue tests run, then lifecycle caller returns before provider completion.
    - Given delivery fails permanently, when tests inspect run state, then core run status is unchanged and notification status is failed.

### PR 2: Provider adapters and safe rendering

**Shippable State:** Operators can send redacted test notifications to Telegram or Slack through fakeable provider adapters, while provider failures remain typed delivery state.

- [ ] **TRD-006** — Harden renderer/redactor for safe operator-facing text, logs, telemetry, and provider errors (4h) [satisfies REQ-005] [depends: TRD-001]
  - Validates PRD ACs: AC-005-1, AC-005-2
  - Implementation AC checklist:
    - Given metadata contains prompt, env, artifact, token, private URL, or webhook values, when rendered/logged, then only allowlisted redacted fields remain.
    - Given provider errors include credentials, when recorded, then redacted reason is persisted and emitted.

- [ ] **TRD-006-TEST** — Test safe rendering/redaction for Telegram tokens, Slack webhooks, private URLs, prompts, env, and artifacts (4h) [verifies TRD-006] [satisfies REQ-005] [depends: TRD-006]
  - Validates PRD ACs: AC-005-1, AC-005-2
  - Implementation AC checklist:
    - Given representative secret-bearing inputs, when renderer/redactor tests run, then raw secret substrings are absent.
    - Given allowed run/task/phase metadata, when tests run, then safe identifiers remain.

- [ ] **TRD-007** — Implement Telegram Bot API provider adapter behind `Messaging.Provider` (5h) [satisfies REQ-003] [satisfies REQ-016] [depends: TRD-005] [depends: TRD-006]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-016-1
  - Implementation AC checklist:
    - Given token/chat id config is valid, when Telegram sends, then adapter posts `sendMessage` with safe text and bounded timeout.
    - Given auth, rate-limit, timeout, or network failure, when adapter returns, then `DeliveryResult` carries typed redacted reason and retryability.
    - Given destination config is invalid, when selected, then `telegram_destination` validation fails before network I/O.

- [ ] **TRD-007-TEST** — Test Telegram endpoint, method, JSON body, timeout, retry classes, invalid config, and redaction without network (4h) [verifies TRD-007] [satisfies REQ-003] [satisfies REQ-015] [satisfies REQ-016] [depends: TRD-007]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-015-1, AC-016-1
  - Implementation AC checklist:
    - Given a fake HTTP client, when tests run, then endpoint/method/body/timeout match Telegram contract.
    - Given each failure class, when tests run, then retryable and non-retryable results are distinguished.

- [ ] **TRD-008** — Implement Slack incoming-webhook provider adapter behind `Messaging.Provider` (4h) [satisfies REQ-004] [satisfies REQ-016] [depends: TRD-005] [depends: TRD-006]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-016-1
  - Implementation AC checklist:
    - Given Slack webhook config is valid, when Slack sends, then adapter posts safe `text` to the configured webhook with bounded timeout.
    - Given both Telegram and Slack config exist but provider is Slack, when delivery runs, then Telegram adapter is not called.
    - Given Slack auth/rate-limit/timeout/network failure, when adapter returns, then delivery failure is typed and redacted.

- [ ] **TRD-008-TEST** — Test Slack webhook request, provider routing, timeout, retry classes, invalid config, and redaction without network (4h) [verifies TRD-008] [satisfies REQ-004] [satisfies REQ-015] [satisfies REQ-016] [depends: TRD-008]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-015-2, AC-016-1
  - Implementation AC checklist:
    - Given fake Slack HTTP client, when tests run, then webhook request shape matches contract.
    - Given provider is Slack with Telegram config also present, when tests run, then no Telegram request is observed.

### PR 3: Notification triggers and noise controls

**Shippable State:** Operators receive configured Telegram/Slack alerts for collab URLs, stalls, failures, and action-needed events; duplicate and routine update noise is suppressed.

- [ ] **TRD-009** — Emit `collab_url` notifications from structured phase artifacts and safe URL output patterns (5h) [satisfies REQ-008] [satisfies REQ-005] [depends: TRD-005]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-005-2
  - Implementation AC checklist:
    - Given a phase artifact/output exposes a collaboration URL, when phase output is recorded, then one `collab_url` notification includes run/task/phase/url/expiration when known.
    - Given no URL exists, when a collaboration phase needs action, then no URL is invented and an action/failure notification can be emitted instead.

- [ ] **TRD-009-TEST** — Test collab URL extraction, non-invention, redaction, and correlation-id dedupe (4h) [verifies TRD-009] [satisfies REQ-008] [satisfies REQ-005] [satisfies REQ-015] [depends: TRD-009]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-005-2, AC-015-3
  - Implementation AC checklist:
    - Given supported URL labels in artifacts/output, when tests run, then exactly one URL notification is enqueued.
    - Given tokenized/private URLs, when tests inspect persisted/rendered data, then secrets are redacted.

- [ ] **TRD-010** — Emit `stall` notifications from stale/stall detection paths without adding a second detector (4h) [satisfies REQ-009] [satisfies REQ-011] [depends: TRD-005]
  - Validates PRD ACs: AC-009-1, AC-009-2, AC-011-1
  - Implementation AC checklist:
    - Given `Recovery.do_detect/1` or `StallDetector` records a stale/stall fact, when messaging is enabled for `stall`, then one notification with suggested next action is enqueued.
    - Given repeated scans happen inside the dedupe window, when notifications evaluate, then duplicates are suppressed by correlation id.

- [ ] **TRD-010-TEST** — Test stall trigger from existing recovery/stall facts and duplicate suppression (3h) [verifies TRD-010] [satisfies REQ-009] [satisfies REQ-011] [satisfies REQ-015] [depends: TRD-010]
  - Validates PRD ACs: AC-009-1, AC-009-2, AC-011-1, AC-015-3
  - Implementation AC checklist:
    - Given a stale active run crosses threshold, when trigger tests run, then one `stall` notification is enqueued.
    - Given same run remains stale, when scan repeats, then provider delivery is suppressed.

- [ ] **TRD-011** — Emit `failure` notifications from phase/run failed and cancelled transitions with recursion guard (4h) [satisfies REQ-010] [satisfies REQ-006] [depends: TRD-005]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-006-2
  - Implementation AC checklist:
    - Given phase failure is recorded, when transition succeeds, then one phase-level failure notification is enqueued with redacted reason.
    - Given run terminal failed/cancelled transition is recorded, when transition succeeds, then one run-level failure notification is enqueued.
    - Given provider delivery fails, when failure is recorded, then no recursive provider-error notification is emitted.

- [ ] **TRD-011-TEST** — Test phase failure, run failure/cancelled trigger, provider-failure isolation, and recursion guard (4h) [verifies TRD-011] [satisfies REQ-010] [satisfies REQ-006] [satisfies REQ-015] [depends: TRD-011]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-006-2, AC-015-3
  - Implementation AC checklist:
    - Given phase/run failures occur, when tests run, then expected notifications are enqueued exactly once.
    - Given provider fails while reporting a failure, when tests finish, then run state remains sourced from the original run failure only.

- [ ] **TRD-012** — Emit `action_needed` notifications from operator-question/inbox paths (4h) [satisfies REQ-010] [satisfies REQ-011] [depends: TRD-005]
  - Validates PRD ACs: AC-010-3, AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given an agent/operator question requires human input, when the action request is created, then one safe `action_needed` notification is enqueued.
    - Given class is disabled or duplicate correlation id exists, when request repeats, then provider delivery is suppressed and state records why.

- [ ] **TRD-012-TEST** — Test action-needed trigger, safe identifiers, disabled class, and duplicate suppression (3h) [verifies TRD-012] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-015] [depends: TRD-012]
  - Validates PRD ACs: AC-010-3, AC-011-1, AC-011-2, AC-015-3
  - Implementation AC checklist:
    - Given an operator question is ingested, when tests run, then notification metadata has question/run/task ids but no raw prompt leak.
    - Given `action_needed` is disabled, when tests run, then no provider call is attempted.

- [ ] **TRD-013** — Add opt-in `run_update` trigger with class-specific rate limiting (3h) [satisfies REQ-011] [satisfies REQ-002] [depends: TRD-005]
  - Validates PRD ACs: AC-011-2, AC-002-2, AC-002-3
  - Implementation AC checklist:
    - Given `run_update` is enabled, when configured run lifecycle updates occur, then notifications are rate-limited by config.
    - Given `run_update` is disabled by default, when routine run progress occurs, then no provider delivery is attempted.

- [ ] **TRD-013-TEST** — Test run-update disabled default, opt-in delivery, and rate-limit suppression (3h) [verifies TRD-013] [satisfies REQ-011] [satisfies REQ-002] [satisfies REQ-015] [depends: TRD-013]
  - Validates PRD ACs: AC-011-2, AC-002-2, AC-002-3, AC-015-3
  - Implementation AC checklist:
    - Given rapid update events, when rate-limit tests run, then only permitted notifications are delivery-eligible.
    - Given event class is disabled, when trigger runs, then suppression or no-op behavior is explicit.

### PR 4: Operator test-delivery and read surfaces

**Shippable State:** Operators can verify Telegram/Slack config without a workflow and inspect notification delivery state through existing run/debug surfaces.

- [ ] **TRD-014** — Expose notification delivery state in HTTP, MCP, CLI, and debug read surfaces from projections only (4h) [satisfies REQ-013] [satisfies REQ-007] [depends: TRD-004]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-007-2
  - Implementation AC checklist:
    - Given a run has notification attempts, when existing read surfaces render run detail/status, then latest notification state appears without raw event-log reading.
    - Given delivery failed, when rendered, then provider/reason/correlation details are redacted and troubleshooting class is present.

- [ ] **TRD-014-TEST** — Test API/MCP/CLI/debug notification status parity and redaction (4h) [verifies TRD-014] [satisfies REQ-013] [satisfies REQ-005] [depends: TRD-014]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-005-2
  - Implementation AC checklist:
    - Given one projected run with notification failure, when each surface is tested, then field names/status match.
    - Given secrets in failure metadata, when responses are inspected, then raw values are absent.

- [ ] **TRD-015** — Add source-verified API/CLI test-delivery operation for Telegram and Slack (5h) [satisfies REQ-012] [satisfies REQ-003] [satisfies REQ-004] [depends: TRD-007] [depends: TRD-008]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-003-1, AC-003-3, AC-004-1
  - Implementation AC checklist:
    - Given messaging config is valid, when operator invokes test delivery, then `test` notification is sent and provider/destination/status are reported.
    - Given config is invalid, when invoked, then the same validation errors used at runtime are returned.
    - Given CLI syntax is documented, when source is verified, then Go command names/flags match implementation.

- [ ] **TRD-015-TEST** — Test test-delivery success/failure envelopes and CLI/API error mapping (4h) [verifies TRD-015] [satisfies REQ-012] [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-015] [depends: TRD-015]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-003-1, AC-003-3, AC-004-1
  - Implementation AC checklist:
    - Given fake providers return success/auth/rate-limit/network/malformed failures, when tests run, then envelopes distinguish each class.
    - Given config invalid, when CLI/API tests run, then no provider call occurs.

### PR 5: Documentation, hardening, and end-to-end validation

**Shippable State:** Operators can configure, test, troubleshoot, and trust Telegram/Slack messaging with documented behavior and full contract tests passing.

- [ ] **TRD-016** — Update operator/developer docs for setup, config, secrets, event classes, test delivery, troubleshooting, and provider extension (5h) [satisfies REQ-014] [satisfies REQ-016] [depends: TRD-015]
  - Validates PRD ACs: AC-014-1, AC-014-2, AC-016-1
  - Implementation AC checklist:
    - Given an operator wants Telegram, when reading docs, then bot creation, chat id discovery, secret refs, event classes, and test delivery are clear.
    - Given delivery fails, when reading troubleshooting docs, then disabled config, malformed destination, auth, timeout, rate-limit, outage, and redaction are distinguishable.
    - Given a maintainer adds a provider, when reading docs, then behavior/result/redaction/test contracts are stated.

- [ ] **TRD-016-TEST** — Validate docs against source-verified config keys, command syntax, provider behavior, and troubleshooting classes (3h) [verifies TRD-016] [satisfies REQ-014] [satisfies REQ-016] [depends: TRD-016]
  - Validates PRD ACs: AC-014-1, AC-014-2, AC-016-1
  - Implementation AC checklist:
    - Given docs mention env/config/CLI identifiers, when verification runs, then every identifier exists in source or is explicitly marked planned.
    - Given docs mention provider behavior, when checked, then callback/result names match source.

- [ ] **TRD-017** — Add architecture guardrails preventing direct provider calls outside messaging adapters (3h) [satisfies REQ-001] [satisfies REQ-016] [depends: TRD-007] [depends: TRD-008]
  - Validates PRD ACs: AC-001-3, AC-016-1
  - Implementation AC checklist:
    - Given run/recovery/inbox modules emit notifications, when source is inspected, then they call `ForemanServer.Messaging` only.
    - Given provider modules exist, when a future provider is added, then no scheduler/run changes are required.

- [ ] **TRD-017-TEST** — Test/static-scan provider isolation from scheduler, recovery, run executor, and inbox code (2h) [verifies TRD-017] [satisfies REQ-001] [satisfies REQ-016] [depends: TRD-017]
  - Validates PRD ACs: AC-001-3, AC-016-1
  - Implementation AC checklist:
    - Given source files are scanned, when tests run, then forbidden direct provider module references outside messaging/providers are absent.

- [ ] **TRD-018** — Add end-to-end fake-provider flow for collab URL, stall, failure, action-needed, duplicate, disabled, and test events (6h) [satisfies REQ-006] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-012] [satisfies REQ-015] [depends: TRD-009] [depends: TRD-010] [depends: TRD-011] [depends: TRD-012] [depends: TRD-013] [depends: TRD-015]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-008-1, AC-009-1, AC-010-1, AC-010-2, AC-010-3, AC-011-1, AC-011-2, AC-012-1, AC-015-3
  - Implementation AC checklist:
    - Given configured fake providers and representative run events, when E2E tests run, then every required event class is enqueued/projected exactly once or suppressed with reason.
    - Given provider I/O fails, when flow completes, then run state remains correct and notification failure is visible.
    - Given restart/catch-up occurs, when dispatcher resumes, then no accepted notification is silently lost.

- [ ] **TRD-018-TEST** — Run focused ExUnit suites, Go CLI tests/build for changed commands, format, and documentation gate checks (4h) [verifies TRD-018] [satisfies REQ-014] [satisfies REQ-015] [depends: TRD-018]
  - Validates PRD ACs: AC-014-1, AC-014-2, AC-015-1, AC-015-2, AC-015-3
  - Implementation AC checklist:
    - Given implementation is complete, when focused tests and format/build gates run, then all pass or unrelated pre-existing failures are reported.
    - Given docs/operator expectations changed, when doc gate runs, then required docs are updated surgically.

## Sprint Planning

## Sprint 1: Durable messaging delivery core

PR 1 and PR 2. Outcome: existing foundation verified, dispatcher added, safe rendering hardened, and Telegram/Slack adapters available behind fakeable contracts.

## Sprint 2: Trigger integration and operator read/test surfaces

PR 3 and PR 4. Outcome: collab URL, stall, failure, action-needed, and opt-in run-update notifications plus run detail and test-delivery surfaces.

## Sprint 3: Docs, guardrails, and end-to-end proof

PR 5. Outcome: setup/troubleshooting/extension docs, architecture isolation tests, and E2E fake-provider validation.

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Provider-neutral notification boundary | TRD-001, TRD-017 | TRD-001-TEST, TRD-017-TEST |
| REQ-002 | Safe messaging config resolution | TRD-002, TRD-013 | TRD-002-TEST, TRD-013-TEST |
| REQ-003 | Telegram bot notifications | TRD-007, TRD-015 | TRD-007-TEST, TRD-015-TEST |
| REQ-004 | Slack webhook notifications | TRD-008, TRD-015 | TRD-008-TEST, TRD-015-TEST |
| REQ-005 | Safe operator-facing rendering/redaction | TRD-001, TRD-006, TRD-009, TRD-014 | TRD-001-TEST, TRD-006-TEST, TRD-009-TEST, TRD-014-TEST |
| REQ-006 | Async non-blocking run progress | TRD-003, TRD-005, TRD-011, TRD-018 | TRD-003-TEST, TRD-005-TEST, TRD-011-TEST, TRD-018-TEST |
| REQ-007 | Notification lifecycle state | TRD-003, TRD-004, TRD-005 | TRD-003-TEST, TRD-004-TEST, TRD-005-TEST |
| REQ-008 | Collaboration URL notifications | TRD-009, TRD-018 | TRD-009-TEST, TRD-018-TEST |
| REQ-009 | Stall notifications | TRD-010, TRD-018 | TRD-010-TEST, TRD-018-TEST |
| REQ-010 | Failure/action-needed notifications | TRD-011, TRD-012, TRD-018 | TRD-011-TEST, TRD-012-TEST, TRD-018-TEST |
| REQ-011 | Duplicate/noisy update suppression | TRD-002, TRD-003, TRD-010, TRD-012, TRD-013, TRD-018 | TRD-002-TEST, TRD-003-TEST, TRD-010-TEST, TRD-012-TEST, TRD-013-TEST, TRD-018-TEST |
| REQ-012 | Test-delivery operator flow | TRD-015, TRD-018 | TRD-015-TEST, TRD-018-TEST |
| REQ-013 | Delivery state in read surfaces | TRD-004, TRD-014 | TRD-004-TEST, TRD-014-TEST |
| REQ-014 | Setup and troubleshooting docs | TRD-016, TRD-018 | TRD-016-TEST, TRD-018-TEST |
| REQ-015 | Provider contracts and trigger tests | TRD-007, TRD-008, TRD-009, TRD-010, TRD-011, TRD-012, TRD-013, TRD-015, TRD-018 | TRD-007-TEST, TRD-008-TEST, TRD-009-TEST, TRD-010-TEST, TRD-011-TEST, TRD-012-TEST, TRD-013-TEST, TRD-015-TEST, TRD-018-TEST |
| REQ-016 | Extensible provider interface | TRD-001, TRD-007, TRD-008, TRD-016, TRD-017 | TRD-001-TEST, TRD-007-TEST, TRD-008-TEST, TRD-016-TEST, TRD-017-TEST |

Traceability check: 16 requirements covered, 0 uncovered, 0 orphaned annotations.

## 8. Adversarial Review

### Architecture Issues

1. **Live projection subscription alone can lose work on restart.** Resolution: dispatcher must have durable catch-up keyed by notification id/attempt id, not only `ProjectionStore.subscribe/0`.
2. **Stall source ambiguity can create duplicate alert policies.** Resolution: messaging observes existing recovery/stall facts and correlation-id dedupe; it does not add a new stall detector.
3. **Provider failure notification can recurse.** Resolution: provider failures terminate as notification delivery state and never enqueue a second provider-error notification.

### Coverage Issues

1. **Existing core foundation is already partially complete, but providers/dispatcher/triggers are absent.** Resolution: mark verified foundation tasks complete and keep remaining delivery/trigger work pending with explicit dependencies.
2. **Collab URL extraction from text can leak tokenized URLs.** Resolution: prefer structured artifacts, support bounded known output labels, and redact before persistence/log/chat.
3. **Docs can drift from actual CLI/API syntax.** Resolution: docs task requires fresh Go source/build verification for any new CLI command.

### Dependency and Estimate Issues

1. **Trigger PR depends on durable dispatcher and adapters.** Resolution: PR 3 depends on PR 1/2; trigger code calls only the messaging boundary.
2. **Test-delivery command estimate depends on choosing API-only vs API+Go CLI.** Resolution: task includes source verification and permits API/CLI mapping under the existing command policy.
3. **Restart catch-up can expand dispatcher scope.** Resolution: dispatcher task is capped at 6h and must fail visibly if durable claim/replay semantics need a separate design.

### Testability Issues

1. **250 ms non-blocking claim needs deterministic proof.** Resolution: use fake slow provider/clock and assert the lifecycle caller returns before provider completion.
2. **Safe rendering can become subjective.** Resolution: renderer tests assert concrete allowlist/denylist keys and exact redaction of representative secrets.
3. **No-network provider contracts must be pinned.** Resolution: adapters accept injectable/fake HTTP clients; CI never calls Telegram or Slack.

## 9. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4.6 | Boundary/config/aggregate/projection exist; missing dispatcher/providers/triggers/surfaces are explicitly placed. |
| Task coverage | 4.7 | All 16 PRD requirements and all 38 ACs map to implementation and test tasks. |
| Dependency clarity | 4.5 | PR order is acyclic; triggers wait for dispatcher/adapters; docs and E2E come last. |
| Estimate confidence | 4.5 | No task exceeds 6h; largest risks are dispatcher durability and CLI/API test-delivery shape. |
| Overall | 4.6 | PASS |

Gate decision: **PASS — ready for implementation planning after approval**.

## 10. Validation Plan

- `cd packages/foreman_server && mix format --check-formatted`
- Focused ExUnit suites for messaging DTO/config/aggregate/projection/dispatcher/provider/trigger modules.
- HTTP/MCP/Go CLI tests for delivery state and test-delivery surfaces; verify Go CLI against source or fresh `go build ./cmd/foreman`.
- Documentation gate: consider `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md`; update only docs whose operator expectations changed.
- `git diff --check`

## 11. Next Steps

After review/approval:

```bash
/ensemble-configure-team docs/TRD/TRD-2026-a8fc7664-telegram-slack-messaging.md
/ensemble-implement-trd-beads docs/TRD/TRD-2026-a8fc7664-telegram-slack-messaging.md
```

## 12. Changelog

### 1.0.0 — 2026-09-05

- Created TRD from `PRD-2026-a8fc7664` with shared micro UUID correlation.
- Source-verified existing messaging foundation and remaining provider/dispatcher/trigger gaps.
- Defined five shippable PR boundaries, 32 tasks, full REQ/AC traceability, and design readiness score 4.6.
