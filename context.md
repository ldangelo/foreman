# Code Context

## Files Retrieved
1. `docs/TRD/TRD-2026-cfb5fec3-telegram-slack-messaging.md` (lines 1-200) - PR1 tasks TRD-001..004 scope, architecture, ACs.
2. `packages/foreman_server/lib/foreman_server/event_codec.ex` (lines 1-220) - strict event registry/decoding rules.
3. `packages/foreman_server/lib/foreman_server/aggregate/actor.ex` (lines 1-180, 533-717) - aggregate command/event protocol, deterministic `command_id`, struct event normalization.
4. `packages/foreman_server/lib/foreman_server/command_gateway.ex` (lines 1-220) - mutation boundary and operator/system dispatch.
5. `packages/foreman_server/lib/foreman_server/command_router.ex` (lines 260-590) - aggregate routing, post-commit projection apply, add `notification:` route.
6. `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex` (lines 1-330) - good model for typed commands/events plus map-envelope commands.
7. `packages/foreman_server/lib/foreman_server/aggregates/project.ex` (lines 1-180) - project aggregate config merge path.
8. `packages/foreman_server/lib/foreman_server/events/project_registered.ex` (lines 1-10) - strict project registered event currently lacks `config`.
9. `packages/foreman_server/lib/foreman_server/events/project_updated.ex` (lines 1-9) - strict project updated event currently lacks `config` despite projection reading it.
10. `packages/foreman_server/lib/foreman_server/projection_store.ex` (lines 1-130, 168-248, 390-440, 430-520, 799-897, 964-1120, 1747) - projection state/query/apply patterns.
11. `packages/foreman_server/lib/foreman_server/workflow/phase_spec.ex` (lines 1-116) - whitelist normalize-once pattern. Do not hide notifications in phase maps.
12. `packages/foreman_server/lib/foreman_server/mcp/tools.ex` (lines 17-71, 570-587, 970-1029) - typed DTOs and RunStatus builder from run + phases.
13. `packages/foreman_server/test/foreman_server/aggregates/run_slots_test.exs` (lines 1-180) - aggregate test style with codec round-trip.
14. `packages/foreman_server/test/foreman_server/event_codec_test.exs` (lines 1-160) - strict codec tests.
15. `packages/foreman_server/test/foreman_server/projection_store_runs_test.exs` (lines 1-180) - projection reset/apply/read test pattern.

## Key Code

- EventCodec auto-registers new events from `lib/foreman_server/events/*.ex`; no manual registry. Strict rejects unknown keys and missing enforced keys: `event_codec.ex` lines 1-22, 115-220.
- Aggregate actor accepts event specs or typed event structs. It derives persisted event type from struct module and stringifies payload: `aggregate/actor.ex` lines 686-710.
- Command id gives deterministic event id / idempotency: `aggregate/actor.ex` lines 533-541.
- Router needs route for `notification:` stream: add in `CommandRouter.aggregate_module_for/1` near `command_router.ex` lines 571-590.
- ProjectionStore public surfaces:
  - `run/1`: `projection_store.ex` lines 168-170, handler lines 390-397.
  - `phases_for_run/1`: lines 245-248, handler lines 688-696.
  - `subscribe/0` and broadcast after apply/rebuild: lines 109-111, 459-482.
- Project config path already exists in aggregate/projection, but event structs are too strict:
  - Aggregate merges `:config` on ProjectUpdated: `aggregates/project.ex` lines 43-59.
  - Projection reads optional config: `projection_store.ex` lines 876-891.
  - `Events.ProjectUpdated` only declares `[:project_id, :task_provider]`; EventCodec will reject `config`: `events/project_updated.ex` lines 1-9. Same for `ProjectRegistered`: `events/project_registered.ex` lines 1-10.
- MCP RunStatus DTO currently has no notification field. Extend struct + builder if TRD says run status/API/MCP detail includes failed critical notifications: `mcp/tools.ex` lines 17-38, 970-995.

## Architecture

- Mutations must go through `CommandGateway.dispatch_system/2` for PR1 messaging internals. Do not expose operator messaging commands yet unless TRD later requires.
- New `ForemanServer.Messaging.notify/1` should validate DTO/config then dispatch system command to `aggregate_id: "notification:<notification_id-or-correlation>"`, `type: "notification.enqueue"`, deterministic `command_id`.
- New `ForemanServer.Aggregates.Notification` should mirror `RunSlots`: state struct, typed event apply clauses, map-envelope command clauses, pure helper validation.
- New events under `lib/foreman_server/events/`: likely `NotificationEnqueued`, `NotificationSuppressed`, `NotificationDeliveryAttempted`, `NotificationDeliverySucceeded`, `NotificationDeliveryFailed`. Include only fields projected/needed by PR1. Use `@enforce_keys` for durable identity/status fields.
- ProjectionStore should add `notifications` state or fold directly into each run. Minimal PR1: store per-run notification summary on run projection at `:notifications` and update on notification lifecycle events. Preserve `run/1` nil semantics.
- Config resolver should normalize workflow/project/app defaults once. Workflow notifications likely from `workflow_snapshot["notifications"]` at messaging boundary, not `PhaseSpec`.

## Recommended minimal implementation plan

### TRD-001 DTOs
- Add `lib/foreman_server/messaging/notification.ex`, `destination.ex`, `config.ex`, `delivery_result.ex`.
- Prefer structs with `normalize/1` returning `{:ok, struct}` or `{:error, %ForemanServer.Messaging.Error{code: atom, field: atom, message: binary}}`.
- Whitelist keys. Reject unknown keys. Do not atomize caller strings except known literal map.
- Fields: provider, recipient/destination, event_class, severity, subject, body, url, correlation_id, run_id, project_id, metadata safe subset.
- Severity: finite atoms/strings. Provider: `:telegram | :slack`; unsupported returns typed `:unsupported_provider`.

### TRD-002 Config resolver
- Add `lib/foreman_server/messaging/config_resolver.ex`.
- Inputs: notification + workflow_snapshot/project projection/app env.
- Precedence: workflow `notifications` > project `config.notifications` > `Application.get_env(:foreman_server, :messaging, [])`.
- Disabled / disabled event class returns `{:ok, :suppressed, reason}` or typed suppression data; malformed selected destination returns `{:error, error}`. No fallback provider.
- Update `Events.ProjectUpdated` and possibly `ProjectRegistered` to include `:config` optional field, otherwise strict codec/projection path breaks.

### TRD-003 Aggregate/events
- Add route: `def aggregate_module_for("notification:" <> _), do: ForemanServer.Aggregates.Notification`.
- Commands: `notification.enqueue`, `notification.delivery_attempt`, `notification.delivery_success`, `notification.delivery_failure`. PR1 may only use enqueue/suppress plus result commands tested directly.
- State: exists?, notification_id, correlation_id, run_id, provider, destination_ref, status, last_attempt_id, last_delivery, dedupe ledger/timestamps.
- Dedupe: same correlation inside window emits `NotificationSuppressed` with reason `duplicate`; outside window enqueue allowed or new id. Decide id derivation before coding.
- Return typed event structs; actor persists them fine.

### TRD-004 Projection
- Extend `ProjectionStore.initial_state/0` or run projection fold. Minimal: on notification events w/ `run_id`, update run map `:notifications` list/map.
- Suggested shape on run: `%{notifications: %{latest: [...], failed_critical: [...], by_id: %{...}}}` or simpler list if tests only require latest state/duplicate skip.
- Add apply clauses before catch-all at `projection_store.ex` line 1747.
- Extend MCP `RunStatus` only if tests cover `foreman_run_status`; otherwise `ProjectionStore.run/1` enough for PR1 but TRD says run detail DTOs, so likely add `notifications` field.

## Tests

- Add:
  - `test/foreman_server/messaging/notification_test.exs` - valid/invalid DTOs, unknown keys, safe metadata allowlist, unsupported provider.
  - `test/foreman_server/messaging/config_resolver_test.exs` - precedence, disabled classes, malformed destination no fallback.
  - `test/foreman_server/aggregates/notification_test.exs` - enqueue/suppress/attempt/success/failure state transitions; map commands and typed events.
  - `test/foreman_server/event_codec_notification_test.exs` or extend codec test - each notification event decodes, rejects unknown keys.
  - `test/foreman_server/projection_store_notifications_test.exs` - apply notification events then read `ProjectionStore.run/1`; failed critical visible; duplicate suppressed visible.
  - If extending MCP DTO: add/update `test/foreman_server_web/mcp/tools/*` or existing MCP tools tests for run_status.
- Use `ProjectionStoreRunsTestHelper` pattern (`ProjectionStoreReset.reset!`, `apply_events`) for projection tests.
- Use `RunSlotsTest` style for aggregate tests: apply event, handle map envelope, codec round-trip.

## Risks / findings

- medium: `ProjectUpdated` projection expects optional `config`, but typed event struct omits it. Adding messaging project config needs event struct update + codec replay tests.
- medium: `ProjectRegistered` aggregate/projection has config handling, but event struct omits `config`; registering project w/ config may fail strict decode later.
- medium: dedupe window needs deterministic timestamp source for tests; avoid wall clock hidden in aggregate unless injectable or assert loosely.
- low: EventCodec registry auto derives; new event files require compile, not manual map update.
- low: Do not put provider I/O in PR1. Keep dispatcher/providers for later PR.

## Start Here

Open `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`. It shows the cleanest existing pattern for typed structs, map-envelope system commands, idempotent/no-op handling, and aggregate tests.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete code-context findings cite exact files/line ranges and include severity-tagged risks."
    }
  ],
  "changedFiles": [
    "context.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "git status --short && git diff --stat",
      "result": "passed",
      "summary": "No tracked/staged repo changes before writing context artifact."
    }
  ],
  "validationOutput": [
    "Read-only scout. Findings written to context.md."
  ],
  "residualRisks": [
    "medium: ProjectUpdated/ProjectRegistered event structs omit config while aggregate/projection paths can carry config.",
    "medium: notification dedupe timestamp source must be testable/deterministic."
  ],
  "noStagedFiles": true,
  "diffSummary": "Only runtime artifact context.md written; no source/test edits.",
  "reviewFindings": [
    "medium: packages/foreman_server/lib/foreman_server/events/project_updated.ex:1 - strict event struct lacks optional config read by projection; messaging project config will be rejected unless added.",
    "medium: packages/foreman_server/lib/foreman_server/events/project_registered.ex:1 - strict event struct lacks optional config; registration config replay may fail if used."
  ],
  "manualNotes": "Read-only per task; no source changes or tests added."
}
```
