# Repository-Rules Review Report

## Review engine

Reviewer: repository-rules review phase agent (no external CLI).
Rules source: repository-root `AGENTS.md` (Foreman agent context) applied exactly.
Diff range: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH=main`, confirmed set).

Diff touches:
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`
- `packages/foreman_server/test/foreman_server_web/live/project_workspace_pr_actions_live_test.exs`
- `docs/reports/foreman-coord-e992a1910e5cc00b/FIX_REPORT.md` (Foreman phase artifact)
- `docs/reports/foreman-coord-e992a1910e5cc00b/REVIEW_CODERABBIT_REPORT.md` (Foreman phase artifact)

Carry-forward: previous phase's `REVIEW_CODERABBIT_REPORT.md` is present. Its
unresolved-findings block is empty (CodeRabbit round 1 clean, 0 findings). No
findings to carry forward.

## Findings

No new violations found. The diff is a surgical UI change (Gap 1: thread
controls wrapped in a collapsed `<details>` labelled "Actions") plus its test.

Checked specifically:
- Error handling hiding failures — N/A (no error paths touched).
- Untyped/ad hoc boundary — N/A (template + CSS only).
- Declared config/enum/manifest value nobody reads — none added.
- Documentation drift — no externally visible identifiers added/removed/renamed
  (no routes, config keys, env vars, CLI verbs, MCP tools). `--card-2`/`--muted`
  are pre-existing CSS tokens.
- Surgical-change rule — every changed line traces to Gap 1; no adjacent
  refactor. `<details phx-mounted={JS.ignore_attributes("open")}>` follows the
  existing established idiom in the same file (lines 136, 172, 248, 745) and
  `JS.ignore_attributes/1` exists in `deps/phoenix_live_view`.

## Fixed

None — no violations required a fix.

## Declined

None.

## Verification

- `MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_pr_actions_live_test.exs` → **9 passed**, exit 0 (run with `DATABASE_URL`/`EVENTSTORE_URL` unset so test config defaults to the foreman Postgres).
- `mix format --check-formatted` on the three changed source/test files → exit 0.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
