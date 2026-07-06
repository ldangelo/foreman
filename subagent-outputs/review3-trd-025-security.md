## Review

- Correct:
  - `WorkerStarted` stores redacted env values only: `worker_protocol.ex:38`, `:96-98`.
  - Env key metadata remains: `prepared_env_keys`, `stripped_env_keys`, `scoped_secret_keys` at `worker_protocol.ex:39-41`.
  - Projection does not store `prepared_env`; only worker status/current phase/adapter/artifacts: `projection_store.ex:412-428`.
  - Debug raw path sanitizes payload/metadata: `debug_views.ex:139-147`; compact path avoids payload dump: `debug_views.ex:150-161`.
  - Tests assert redacted payload + metadata keys + EventStore/projection absence: `security_test.exs:53-87`, `:137-142`.
  - Auth/start/audit regression covered: `worker_protocol_test.exs:33-74`, `security_test.exs:145-185`.

- Blocker:
  - None found.

- Fixes worth doing now:
  - Add `host-leak`, `sock`, `gh` to `assert_persisted_payloads_exclude_secret_values/1` for fuller forbidden-value coverage.
  - Optional: decode/read event log file in security test to prove on-disk durable payload, not just `EventStore.all()`.

- Optional:
  - Add explicit `DebugViews.logs(..., mode: :raw)` assertion for a `WorkerStarted` event with secrets.

- Commands:
  - `cd packages/foreman_server && mix test test/security_test.exs test/worker_protocol_test.exs test/debug_views_test.exs` → 13 tests, 0 failures.
  - `cd packages/foreman_server && mix test` → 113 tests, 0 failures.
  - `git status --short` → clean.

Note: Did not write `subagent-outputs/review3-trd-025-security.md`; task also said “No edits,” so no-edit won.