## Review

- Correct:
  - Scoped Elixir tests pass:
    - `mix test test/attach_bridge_test.exs`: 8 tests, 0 failures.
    - `mix test`: 81 tests, 0 failures.
  - Review-round-1 fixes mostly covered:
    - Completed-run attach: `attach_bridge.ex:6`, tests `attach_bridge_test.exs:49-69`.
    - Stale metadata reject: `attach_bridge.ex:213-224`, tests `:57-69`.
    - Run/phase validation before interrupt/resume side effects: `attach_bridge.ex:118-168`, tests `:172-204`.
    - HTTP 404/409 mapping: `router.ex:126-130`, `:146-153`, `:171-178`.
    - Restart replay test now restarts app: `attach_bridge_test.exs:207-227`, helper `:282-286`.

- Blocker:
  - Strict AC-018-1 CLI validation still missing.
  - PRD says CLI path: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:452`.
  - Existing TS CLI attach path uses local/daemon run lookup + `handleDefaultAttach`, not Elixir `/api/v1/runs/:id/attach`: `src/cli/commands/attach.ts:126-187`, `:747-757`.
  - CLI tests only assert command loads/options: `src/cli/__tests__/attach.test.ts:5-8`, `attach-follow.test.ts:4-8`.
  - Result: AC-018 bridge HTTP is tested; user-visible CLI attach-to-bridge is not proven.

- Fix worth doing now:
  - Idempotent attach replay is wrong for multi-worker runs.
  - Duplicate handler returns run-level latest projection: `attach_bridge.ex:253-256`.
  - Projection stores only `attach_requests[run_id]`: `projection_store.ex:498-505`.
  - Proof command returned `%{first: "w1", second: "w2", third: "w2"}` when retrying `worker_id: "w1"` after attaching `w2`.
  - Fix: on duplicate, return original event by `stream_id + idempotency_key`, or key projection by run+worker. Add multi-worker retry test.

- Optional:
  - Add HTTP negative tests still missing from review-1 notes:
    - `GET /attach` unknown run -> 404.
    - unauthorized `POST /interrupt` and `/resume`.
    - missing `phase_id`, missing `next_action`.
  - Current router code likely handles these, but tests do not lock them.

- Commands:
  - `git status --short`: clean.
  - `mix test test/attach_bridge_test.exs`: passed, 8 tests.
  - `mix test`: passed, 81 tests.
  - `npx vitest run src/cli/__tests__/attach.test.ts src/cli/__tests__/attach-follow.test.ts --reporter=dot`: passed, 2 tests.
  - `mix run --no-start -e <multi-worker idempotency proof>`: exposed wrong retry result.

Note: output file not written. User also said no edits; no-edit wins.