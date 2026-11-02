CodeRabbit review phase complete.

**Engine:** `coderabbit review --agent --base main` → completed, 2 findings (1 minor, 1 trivial).

**Fixed (both, round 1):**
- `project_view.ex:30` — narrowed `blank_to_nil(_)` catch-all to `blank_to_nil(nil)`. Present-but-non-string goal now raises instead of silently becoming `nil` (§5.3 Absent ≠ malformed).
- `project_workspace_live_test.exs:1207` — replaced two weak `html =~` asserts w/ `has_element?(view, "aside.ws-side > section.ws-panels")`, pinning parent-child structure.

**Declined:** none.

**Verification:**
- Affected tests: `mix test --warnings-as-errors` on the two files → **50 passed**, exit 0. (Had to `unset DATABASE_URL EVENTSTORE_URL` — inherited env pointed at langfuse-stack PG :55434 w/ wrong password; test default uses foreman PG :55432.)
- `mix format --check-formatted` on changed files → exit 0.

Doc gate: no externally visible identifiers changed (private fn + test only). No `.beads/` touched. Fixes left uncommitted for Foreman to commit. Report written to `docs/reports/foreman-coord-322b62d929d673ec/REVIEW_CODERABBIT_REPORT.md`; unresolved-findings block empty.