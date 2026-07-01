## Review

REJECTED for test/validation sufficiency. No edits made. Output file not written due explicit no-edit instruction.

### Correct
- Git status clean. Current diff empty.
- Targeted inbox tests pass: `4 tests, 0 failures`.
- Full Elixir package tests pass: `46 tests, 0 failures`.
- Format/compile/typecheck pass:
  - `mix format --check-formatted`
  - `mix compile --warnings-as-errors`
  - `npx tsc --noEmit`
- AC-015-2 has useful coverage:
  - `packages/foreman_server/test/inbox_test.exs:44-78`
  - Tasks `RunStarted`, sends operator msg, asserts `queued`, updates to `delivered`.
- AC-015-3 has useful in-process watch coverage:
  - `packages/foreman_server/test/inbox_test.exs:81-110`
  - `assert_receive {:inbox_update, ...}` proves Registry push path.
  - Registry supervised at `packages/foreman_server/lib/foreman_server/application.ex:12`.
  - Notify path at `packages/foreman_server/lib/foreman_server/projection_store.ex:460-487`.
- Missing-run failure path covered:
  - `packages/foreman_server/test/inbox_test.exs:113-117`
  - `active_run/1` rejects before append at `packages/foreman_server/lib/foreman_server/inbox.ex:166-178`.

### Blocker
- AC-015-1 is not fully proven.
  - PRD requires phase starts/completes/fails: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:413`.
  - Test only exercises `"PhaseStarted"`: `packages/foreman_server/test/inbox_test.exs:26-41`.
  - Fixture includes completed/failed hooks but test never asserts them: `packages/foreman_server/test/fixtures/inbox-mail-hooks.json:5-7`.
  - Grep shows `Inbox.append_phase_mail/3` has no production caller outside tests, so tests do not prove real `PhaseStarted`/`PhaseCompleted`/`PhaseFailed` event flow.

### Blocker
- Restart persistence is not proven.
  - TRD checklist requires server restart/rebuild consistency: `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:637-639`.
  - Test calls same-process `EventStore.rebuild_projections()`: `packages/foreman_server/test/inbox_test.exs:40-41`.
  - That rebuild uses in-memory `state.events`: `packages/foreman_server/lib/foreman_server/event_store.ex:93-94`.
  - No test stops/restarts app with same log path to prove replay from durable file (`event_store.ex:57-62`).

### Fix worth doing now
- Parameterize AC-015-1 test over `PhaseStarted`, `PhaseCompleted`, `PhaseFailed`.
- Add restart replay test:
  - append inbox msg + delivery update
  - stop app
  - restart same `event_log_path`
  - assert `Inbox.list/1` and delivery status survive.
- Add failure tests:
  - terminal run returns `{:run_not_active, run_id}`
  - missing `run_id` / missing `body`
  - `update_delivery` missing msg returns `{:message_not_found, id}`
  - phase mail invalid payload fails cleanly, not crash/partial append.

### Commands run
- `git status --short && git diff --stat && git diff --name-only` → clean.
- `git show --stat 37ce7698`, `0e926e09`, `97c268ea` → inspected.
- `cd packages/foreman_server && mix test test/inbox_test.exs` → pass, 4 tests.
- `cd packages/foreman_server && mix test` → pass, 46 tests.
- `cd packages/foreman_server && mix format --check-formatted` → pass.
- `cd packages/foreman_server && mix compile --warnings-as-errors` → pass.
- `npx tsc --noEmit` → pass.