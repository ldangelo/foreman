## Review
- Correct:
  - Auth header implemented for protected reads.
    - `src/lib/elixir-server-manager.ts:25` reads `FOREMAN_SERVER_AUTH_TOKEN`.
    - `src/lib/elixir-server-manager.ts:37-42` marks `doctor()` / `metrics()` authenticated.
    - `src/lib/elixir-server-manager.ts:50-51,98-100` sends `Authorization: Bearer <token>` only when token exists.
  - No-token behavior covered.
    - `src/lib/__tests__/elixir-server-manager.test.ts:34-42` asserts doctor fetch has no `RequestInit` when no token.
  - Token behavior covered.
    - `src/lib/__tests__/elixir-server-manager.test.ts:45-58` asserts doctor + metrics send bearer header.
  - Server negative auth covered.
    - `packages/foreman_server/test/http_router_test.exs:160-178` asserts missing/wrong token => `401` for `/doctor` + `/metrics`.
  - No doctor/metrics regression found.
    - Router still authorizes and serves both: `router.ex:14-31`.
    - Positive tests assert doctor/metrics `200`: `http_router_test.exs:181-207`.
  - Docs mention token.
    - `README.md:589`
    - `docs/cli-reference.md:333`
    - `docs/user-guide.md:98`

- Blocker:
  - None found.

- Fix worth doing now:
  - None.

- Optional:
  - Test cleanup deletes `process.env.FOREMAN_SERVER_AUTH_TOKEN` instead of restoring prior value: `src/lib/__tests__/elixir-server-manager.test.ts:7-10`. Low risk, but restore pattern is safer for mixed test envs.

- Commands:
  - `npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot` — passed, 5 tests.
  - `(cd packages/foreman_server && mix test test/http_router_test.exs)` — passed, 12 tests.
  - `git status --short` — clean.

- Note:
  - `progress.md` missing (`ENOENT`).
  - Did not write `subagent-outputs/review2-trd-024-auth.md`; task says no edits, and review-only/no-edit wins.