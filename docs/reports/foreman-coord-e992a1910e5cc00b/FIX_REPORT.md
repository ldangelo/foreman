Done. Summary:

**Base reconciliation (critical finding)**
- Task said base on PR #822 branch = "the delivered redesign" w/ 4 gaps.
- Git archaeology: reviewed snapshot `929e3997` (4 gaps) is an **ancestor** of the same branch's evolved tip, merged to `main` as PR #822. My worktree HEAD == main == delivered redesign.
- The continued/merged work **already closed gaps 2, 3, 4**:
  - Gap 2: operator bubble already `var(--card-2)` (layouts.ex:123)
  - Gap 3: `<nav aria-label="Project">` present (project_workspace_live.ex:830)
  - Gap 4: run reports dropped by commit `e8b5215a`; none tracked
- Basing on stale `929e3997` would **revert merged features** (thread sidebar, thread_view.ex, Transcript chunking) → destructive, violates "keep redesign intact". Worked on HEAD per task escape clause.

**Gap 1 (only one still open) — fixed**
- `components.ex` `thread_pane/1`: wrapped `.thread-controls` in collapsed `<details class="thread-controls-details" id="thread-controls-<id>">` + `<summary>Actions</summary>`, `phx-mounted={JS.ignore_attributes("open")}` (matches redesign's other collapsibles). Inner groups unchanged.
- `layouts.ex`: 2 CSS lines (muted summary, 8px top margin when open). No new tokens/colors.
- `project_workspace_pr_actions_live_test.exs`: regression test — controls inside collapsed `details#thread-controls-run:<id>`, summary "Actions", contains PR button. Fails pre-fix, passes post-fix.

**Verification**
- `mix format --check-formatted` (3 files): exit 0, no churn.
- `mix test --warnings-as-errors` (pr_actions, threads, approvals, attention, project_workspace_live): **113 passed**, exit 0.
- Doc gate: no doc-gate identifiers changed (only CSS class + DOM id); grep of CLAUDE.md/README.md/user-guide.md/cli-reference.md → no hits. No doc edits needed.

**Not done (deliberate)**
- Task Prompt said "open a PR", but governing `fix` mission + project invariant say Foreman owns worktree/branch — no commit/push/PR. Changes left **uncommitted**; Foreman opens the PR. 3 files modified, nothing staged, FIX_REPORT untracked (not committed, per gap 4).

Report: `docs/reports/foreman-coord-e992a1910e5cc00b/FIX_REPORT.md`.