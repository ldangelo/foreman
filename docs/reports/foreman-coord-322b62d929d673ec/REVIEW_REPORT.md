# Repository-Rules Review Report

## Review engine

Reviewer: in-repo repository-rules pass against `AGENTS.md` (Working Rules,
Documentation Gate, §5 Typed Boundaries) and the touched files' own idioms.
Diff range: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH=main`), scoped to the
five changed `packages/foreman_server` source/test files.

Previous phase's `REVIEW_CODERABBIT_REPORT.md` is present but is a prose report
with no `FOREMAN_REVIEW_FINDINGS_*` marker block — it records 2 findings both
fixed in that phase, 0 declined, unresolved block empty. Nothing to carry
forward.

## Findings

- Error handling hiding failures — none. `ProjectView.blank_to_nil/1` matches
  only binary and `nil`; a present-but-non-string goal raises (§5.3). No fix.
- Typed boundary — `@type t` updated to include `goal: String.t() | nil`; the
  view returns the declared shape. No ad hoc untyped data. No fix.
- Dead config/enum value — the `goal` config key is now read and rendered in
  the header. No declared-but-unread value introduced. No fix.
- One key convention (§5.4) — `build/1` normalizes config via `stringify/1`
  then reads `config["goal"]`; no `Map.get(:k) || Map.get("k")`. No fix.
- Documentation gate — no externally visible identifier added/removed/renamed
  (route `/dashboard/projects/:id` unchanged; no config key, env var, CLI verb,
  or MCP tool added; CSS classes and `ProjectView.t` are internal). README,
  CLAUDE.md, docs/user-guide.md, docs/cli-reference.md need no edit. No fix.
- Surgical-change / scope — every changed line traces to the layout-shell task;
  chat/overview/library/PR panes preserved, only re-parented into
  `ws-main-col` / `ws-side`. No fix.

## Fixed

None. The diff already satisfies the repository's rules; the two CodeRabbit
findings were resolved in the prior phase.

## Declined

None.

## Verification

- `mix test --warnings-as-errors` on the two touched test files
  (`project_view_test.exs`, `project_workspace_live_test.exs`) → **50 passed**,
  exit 0. (`DATABASE_URL`/`EVENTSTORE_URL` unset so the test config defaults to
  the foreman Postgres on :55432; inherited env pointed at the wrong DB.)
- `mix format --check-formatted` on all five changed files → exit 0.

Post-fix re-read of `git diff main...HEAD`: no new violation introduced (no
fixes were required).

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
