# Developer Report: Fix log view: render run log output in structured readable format

## Approach
Implemented structured log rendering for `foreman inbox task <id> --logs`. The inbox command now calls `ElixirServerClient.logs()` via the Elixir backend to fetch structured run log entries, formats them with timestamps, stream indicators, color coding, and terminal-width truncation, with a raw log file fallback.

## Files Changed
- `src/cli/commands/inbox.ts` — Added `renderLogSection()` async function that calls `ElixirServerClient.logs()`, formats entries with timestamp + stream badge + message, truncates to terminal width, falls back to raw log file on error
- `src/cli/super-tui/panes/DetailPane.ts` — Extended DetailPane to handle `Promise<string>` detail output via `useEffect`/`useState` async unwrapping, enabling async log content in the SuperTUI inbox surface
- `src/cli/__tests__/inbox.test.ts` — Added async test coverage for `renderLogSection()`, updated existing tests to async
- `src/cli/__tests__/inbox-tui-contracts.test.ts` — Updated DetailPane contract tests for async `detailOutput` behavior
- `docs/cli-reference.md` — Documented the new `foreman inbox task <id> --logs` flag

## QA Handoff
- Run `npx vitest run src/cli/__tests__/inbox.test.ts` to verify async log rendering
- Run `npx vitest run src/cli/__tests__/inbox-tui-contracts.test.ts` to verify DetailPane async contract
- Smoke test: `foreman inbox task <run-id> --logs` in a worktree with known run IDs
- 151 tests total in the inbox suite should pass

## Decisions & Trade-offs
- Chose `ElixirServerClient.logs()` over direct file read to leverage the Elixir backend's event filtering and sorting by `occurred_at` + `stream_version`
- Used `Promise<string>` propagation through DetailPane rather than a separate log-specific pane, keeping the existing surface architecture intact
- Raw log file fallback ensures the feature degrades gracefully when the Elixir server is unavailable

## Scope Expansions
- `src/cli/commands/inbox.ts` — Core deliverable. This file was necessary: the inbox command is the entry point for `foreman inbox task <id> --logs`. Minimal change: added `renderLogSection()` and its call site.
- `src/cli/super-tui/panes/DetailPane.ts` — Required by inbox.ts: the SuperTUI DetailPane must unwrap `Promise<string>` to display async log content. Minimal change: added `useEffect`/`useState` async unwrapping for `detailOutput`.
- `src/cli/__tests__/inbox.test.ts` — Test coverage for the new async `renderLogSection()` path.
- `src/cli/__tests__/inbox-tui-contracts.test.ts` — TUI contract tests for DetailPane async output unwrapping behavior.
- `docs/cli-reference.md` — CLI documentation for the new `--logs` flag. Documentation was updated to match the implemented behavior.
- `src/lib/elixir-server-client.ts` — Required fix: the Elixir backend API response for `getRunLogs` changed from an array to `{ run_id, mode, entries }` structure. The client code was updated to unwrap `body.logs.entries` correctly.
- `src/lib/__tests__/elixir-server-client.test.ts` — Test coverage for the updated `getRunLogs` API response structure.
- `reports/DEVELOPER_REPORT.md` — Developer phase report documenting implementation, scope expansions, and QA handoff.

## Known Limitations
- None
