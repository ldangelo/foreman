Repo-rules review done. Summary:

**Engine:** repo-rules phase agent, no external CLI. Base `main` (confirmed set). Range `git diff main...HEAD`.

**Diff reviewed:** Gap 1 UI change — thread controls wrapped in collapsed `<details>` "Actions" (`components.ex` + `layouts.ex`) + its test; plus two Foreman phase-artifact reports.

**Findings:** 0 new violations. Checks:
- No error-hiding, no untyped boundary, no unread config/enum.
- No externally visible identifiers changed → no doc gate action. `--card-2`/`--muted` pre-existing tokens.
- Surgical: every line traces to Gap 1. `JS.ignore_attributes("open")` matches existing idiom (lines 136/172/248/745), fn exists in deps.

**Carry-forward:** CodeRabbit report present, empty findings block → nothing to carry.

**Verification:**
- `mix test --warnings-as-errors` on `project_workspace_pr_actions_live_test.exs` → 9 passed, exit 0.
- `mix format --check-formatted` on 3 changed files → exit 0.

No fixes needed, no commits made (Foreman commits phase work). Report at `docs/reports/foreman-coord-e992a1910e5cc00b/REVIEW_REPORT.md` w/ empty unresolved-findings block.

Note: this run's diff only contains Gap 1 (+reports+test); Gaps 2–4 from the task prompt are not present in this run's diff — out of scope for this review phase, but flagging for operator visibility.