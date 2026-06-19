Did not write output file. No-edit conflicts w/ artifact write.

## Review
- Correct:
  - `/api/v1/doctor` and `/api/v1/metrics` require `authorize/1` when token configured: `packages/foreman_server/lib/foreman_server/http/router.ex:14-30,316-324`.
  - Metrics cover req counters/timers/lag: `Operations.metrics/2` at `packages/foreman_server/lib/foreman_server/operations.ex:108-115`.
  - Lag math uses projection checkpoint event id vs event store order; lagging projection tested: `operations.ex:176-184`, `operations_test.exs:90+`.
  - Debug raw/compact output sanitizes nested payload/metadata, truncates unicode safely: `debug_views.ex:328-372`; tests cover colon/hyphen/json secrets and unicode truncation: `http_router_test.exs:114-151`.
  - Docs mention server doctor metrics in README and CLI ref: `README.md:583-589`, `docs/cli-reference.md:321-333`.

- Blocker:
  - `foreman server doctor` fails against an auth-enabled server. `ElixirServerManager.doctor()` calls `getJson("/api/v1/doctor")` with no `Authorization` header (`src/lib/elixir-server-manager.ts:35-42`), while the router requires `Bearer $FOREMAN_SERVER_AUTH_TOKEN` (`router.ex:316-324`). Other Elixir clients already pass this env token (`src/lib/elixir-server-client.ts:57-65`, `src/cli/commands/import.ts:74`, `src/cli/commands/plan.ts:527`). Fix now: make manager send `Authorization: Bearer ${process.env.FOREMAN_SERVER_AUTH_TOKEN}` for doctor/metrics/protected reads, add Vitest coverage.

- Fix worth doing now:
  - Add an unauthorized test for `/api/v1/doctor` and `/api/v1/metrics`, not just logs. Existing authorized coverage is at `http_router_test.exs:160-185`.

- Optional:
  - Docs should name `FOREMAN_SERVER_AUTH_TOKEN` for server API/doctor/metrics auth. Current CLI/README describe authenticated endpoints but not how operator configures/calls auth.

- Commands:
  - `git status --short && git log --oneline --decorate -n 8`
  - `git show --stat --oneline --decorate 1b7a25bd`
  - `git show --stat --oneline --decorate 38dbc17c`
  - `git diff --stat 38dbc17c..HEAD && git status --short`
  - `cd packages/foreman_server && mix test test/operations_test.exs test/http_router_test.exs` → pass, 15 tests.
  - `cd packages/foreman_server && mix test test/debug_views_test.exs && cd ../.. && npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot` → pass, 6 ExUnit + 4 Vitest.