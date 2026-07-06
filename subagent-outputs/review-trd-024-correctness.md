## Review

REJECTED

- Correct:
  - AC-022 scope found: PRD `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:504-506`; TRD `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:1018-1020`.
  - Doctor checks DB/projections/workers/VCS/providers/integrations in `packages/foreman_server/lib/foreman_server/operations.ex:22-29`.
  - Metrics include counters/timers/projection lag in `operations.ex:107-185`.
  - Debug timeline returns `anomalies.first` in `packages/foreman_server/lib/foreman_server/debug_views.ex:116-125,182-195`.
  - HTTP routes are authenticated for doctor/metrics in `packages/foreman_server/lib/foreman_server/http/router.ex:14-30,316-325`.
  - Tests cover ops/router/manager paths: `packages/foreman_server/test/operations_test.exs:26-95`, `packages/foreman_server/test/http_router_test.exs:160-175`, `src/lib/__tests__/elixir-server-manager.test.ts:32-39`.

- Blocker:
  - CLI doctor cannot call authenticated server doctor.
  - Evidence:
    - Server requires `Authorization: Bearer <FOREMAN_SERVER_AUTH_TOKEN>` when token configured: `router.ex:316-325`.
    - `ElixirServerManager.getJson()` calls `fetch(new URL(...))` with no headers: `src/lib/elixir-server-manager.ts:39-42`.
    - `foreman server doctor` has no token option/env handling before `manager.doctor()`: `src/cli/commands/server.ts:43-50`.
    - Existing manager test asserts URL only, not auth header: `src/lib/__tests__/elixir-server-manager.test.ts:32-39`.
  - Impact: with auth enabled, `foreman server doctor` returns 401 and fails, violating TRD PR6 auth+doctor shippable state `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:743,751` and PRD AC-022-1.

- Fix worth doing now:
  - Add auth header support to `ElixirServerManager` from `FOREMAN_SERVER_AUTH_TOKEN` and/or ctor option.
  - Add Vitest asserting doctor sends bearer header when env/option set.
  - Consider docs note for auth token use.

- Optional:
  - Debug “first inconsistent transition” ordering can be wrong for equal timestamps across streams. `DebugViews.run_events` sorts by `occurred_at` + `stream_version` (`debug_views.ex:130-133`), but `stream_version` is per stream, not global (`event_store.ex:69-70,121-126`). Preserve append order or add global seq if imported events can share timestamps.
  - Metrics are read-time JSON, not telemetry/exporter emission. OK if “emitted” means `/api/v1/metrics`; clarify if external metrics sink expected.

- Commands:
  - `git status --short && git log --oneline -8` — passed.
  - `cd packages/foreman_server && mix test test/operations_test.exs test/http_router_test.exs` — passed, 15 tests.
  - `npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot` — passed, 4 tests.
  - `git status --short` — clean.

Note: did not write `subagent-outputs/review-trd-024-correctness.md`; task says no edit, so no-edit wins.