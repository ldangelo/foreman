Phase 4 done.

## Result

**Scope reviewed:** `git diff main...HEAD` (base `f0f3b083`, HEAD `c4d6cbaa`) — 3 Markdown artifacts under `docs/reports/foreman-beads:foreman:foreman-k9g4n/`, **zero code**.

**Fixed (uncommitted — Foreman commits the phase):**
1. `FIX_REPORT.md` — phase-2 narrative sentence → the sole line `PLAN.md` §3 mandates: `Blocked: depends on PR #942 (foreman-ylwq0), which adds fetch_origin_base/3; no code change here.`
2. `REVIEW_CODERABBIT_REPORT.md` — phase 3 had committed an internal `<analysis>/<summary>` session dump; rewrote as a conforming report stating truthfully that the CodeRabbit engine never ran (CLI present v0.9.6, no output file, phase-3 archive lists the CLI run as pending) ⇒ no findings block, LOW risk block last. Also dropped a stale citation of kata `9j92` (belongs to a different closed run).
3. `REVIEW_REPORT.md` (new) — 5 sections + findings block + LOW risk block last.

**Findings (4):** major/fixed ×2 (the two artifacts above) · major/**open** — the bead is not implementable here: the origin-fetch path `fetch_origin_base/3` exists only in unmerged sibling PR #942 (`mergedAt: null`, merge-base `f0f3b083`); operator must merge #942 and re-run the bead · minor/**declined** — plan-phase commit `1bb84a33` violates `fix-plan.md:17` "Do not commit.", but 49 `[pi]` agent commits already exist across run branches ⇒ repo-wide pre-existing pattern, history rewrite out of scope.

**Validation:** `mix test review_findings_test.exs pr_risk_test.exs` → 105 passed (exit 0) · `mix format --check-formatted` → exit 0 · real parsers: `REVIEW_REPORT.md` → findings **recorded (4)** + judgement **recorded LOW**; coderabbit artifact → findings **absent** (correct) + judgement **recorded LOW** · `git diff main...HEAD` re-read after fixes → Markdown-only, no new violation.

**Doc gate:** no externally visible identifier added/removed/renamed; `grep` in `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` → no stale refs, no edits needed.

Kata issue `skh7` created and closed with evidence. Progress tools (`foreman_inbox_send`, `foreman_task_add_comment`) are not exposed in this phase, so no operator notes were sent; the findings block + kata are the record. `ask_advisor` failed again (Anthropic oauth refresh 400 `invalid_grant`).

**Open for the operator:** merge PR #942, then re-run the bead for graceful degradation on fetch failure.