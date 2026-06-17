## Review

- Correct:
  - `progress.md` missing (`ENOENT`). Read `plan.md`.
  - Commit `47cf8f08` adds tests only.
  - Focused Elixir tests pass: 19 tests, 0 failures.
  - Full Elixir suite + warnings-as-errors pass: 113 tests, 0 failures.
  - Fixes improved:
    - Invalid bearer no-side-effect coverage: `http_router_test.exs:32-52`, `worker_protocol_test.exs:33-43`.
    - Audit replay coverage: `security_test.exs:141-158`.
    - Token stripping test now includes `FOREMAN_SERVER_AUTH_TOKEN`: `security_test.exs:36-70`.
    - Cross-run/project non-leak fixture: `security_test.exs:73-100`.

- Blocker:
  - Secret values are persisted in durable events.
  - PRD says: “Secrets must be redacted from events/logs/projections” (`docs/PRD/...md:565-569`).
  - Impl stores full `prepared_env` in `WorkerStarted` event payload (`worker_protocol.ex:28-40`).
  - Test asserts event contains `"PROJECT_TOKEN" => "project-secret"` and `"RUN_TOKEN" => "run-secret"` (`security_test.exs:53-58`).
  - This validates the wrong security property. Scoped secrets should reach worker execution, not durable event log.

- Fix worth doing now:
  - Redact/remove secret values from persisted `WorkerStarted` payload.
  - Persist only metadata: env keys, stripped keys, scoped secret keys, maybe redacted map values.
  - Add test asserting `EventStore.all()` / event payload does not contain secret values.

- Optional:
  - Add authorized HTTP destructive-command test proving `/api/v1/commands` records audit events end-to-end.
  - Add missing-token worker start no-side-effect test, not just invalid-token.

- Commands:
  - `git show --stat --oneline 47cf8f08` passed.
  - `cd packages/foreman_server && mix test test/security_test.exs test/http_router_test.exs test/worker_protocol_test.exs` passed.
  - `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` passed.

No file written due explicit no-edit instruction.