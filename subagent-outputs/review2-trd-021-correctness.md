## Review — REJECTED

- Correct:
  - Recent completed attach now allowed: `completed` removed from unsupported statuses, `pi_sdk` + recent metadata required. `attach_bridge.ex:6,109-113`.
  - Stale metadata rejected w/ reason. `attach_bridge.ex:202-203`; test `attach_bridge_test.exs:49-69`.
  - HTTP maps auth/404/409. `router.ex:120-130,140-178`.
  - Restart replay covered. `attach_bridge_test.exs:207-227`.

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - Attach GET idempotency can return wrong prior projection.
    - Duplicate handler returns `snapshot.attach_requests[run_id]`, not the event matching the duplicate idempotency key. `attach_bridge.ex:253-256`.
    - Projection is run-keyed and overwritten by any later `AttachRequested`/`AttachUnsupported`. `projection_store.ex:498-505`.
    - Repro: ready attach → missing-worker attach → same ready attach returns `unsupported` for `missing`.
    - Existing test only covers two identical happy GETs. `attach_bridge_test.exs:72-86`.
    - Fix now: on duplicate, fetch payload from matching stream/idempotency key, or key projection by run+event+worker.

- Blocker:
  - Resume after terminal run still appends side effects.
    - `validate_resumable/2` checks run exists, phase known, last event interrupted; it does **not** require active run. `attach_bridge.ex:128-135`.
    - `InteractiveRecoveryResumed` then mutates completed run phase state. `attach_bridge.ex:83-90`, `projection_store.ex:512-520`.
    - Repro: interrupt run → append `RunCompleted` → resume returns `{:ok, ...}` and completed run has `phase_status["developer"] == "resume_requested"`.
    - Violates TRD invalid/unsupported state “fails before side effects.” `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:693-696`.
    - Fix now: add `active_run(run)` to `validate_resumable/2`; test completed/failed/blocked resume returns 409 and no event.

- Optional:
  - CLI AC-018 remains not proven here; fix scope appears HTTP/Elixir only.

- Commands:
  - `git status --short && git log --oneline -5` — clean tracked status; HEAD `0a0ad530`, fix `b1a7c372`.
  - `cd packages/foreman_server && mix test test/attach_bridge_test.exs` — passed, 8 tests.
  - custom `mix run --no-start` idempotency repro — failed behavior observed: third attach returned `unsupported`.
  - custom `mix run --no-start` terminal resume repro — failed behavior observed: resume returned `{:ok, ...}` on completed run.
  - `cd packages/foreman_server && mix test` — passed, 81 tests.

Note: requested output file not written. No-edit instruction wins.