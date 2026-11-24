

Phase 4 done. Repo-rules review of `git diff main...HEAD` (4 files: 3 run reports + docs/user-guide.md).

**Fixed (uncommitted, Foreman commits)**
- `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` — major: phase-3 commit `aa96d402` clobbered the contract-compliant report (from `77e4e158`) with a 19-line prose summary: no `##` sections, no findings block, no risk block, while claiming "JSON blocks validated". Foreman's `ReviewFindings.parse/1` + `PrRisk.parse_judgement/1` couldn't read it → operator saw no findings. Restored; diff vs `77e4e158` = ONE hunk (`## Changes this phase left uncommitted` intro, heading/body now agree).
- `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md` — minor: §5 filtered `go test -run 'TestUserGuide|TestUsageDrift'`; no `TestUsageDrift` exists ⇒ recorded exit 0 proved nothing. Replaced with the 6 real test names.

**Declined**
- `## PR body` convention + body-template setting: convention has ZERO repo-wide hits; `pr_body_headings`/`workflow/pr_body.ex` exist only on upstream `main` (14 commits past merge-base, outside this diff) and main already documents it (docs/user-guide.md:736/:744, README.md:290, docs/cli-reference.md:330/:624). Documenting here = describing code the branch doesn't carry.
- "section above" cross-ref — resolves to real prose (docs/user-guide.md:2974-2999). Not a violation.

**Carried forward:** all 6 phase-3 CodeRabbit findings (source `coderabbit`), all `fixed`.

**Verification**
- `go test ./cmd/foreman/ -run '<6 real names>' -v` → 6 PASS, ok, rc 0
- `mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs` → 3 passed, rc 0
- Parser probe: restored report ⇒ 6 findings + risk LOW; new REVIEW_REPORT.md ⇒ 10 findings + risk LOW
- `git status`: M PLAN.md, M REVIEW_CODERABBIT_REPORT.md, ?? REVIEW_REPORT.md

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_REPORT.md` (sections in contract order; markers column 0, raw JSON, 0 fences).

Progress note sent to inbox (`msg_xA1EYpzD6gUxW3CNeO2G6g`) + task Work Log comment. Kata issue `3kyc` created/claimed/closed.

Caveat: `ask_advisor` unavailable — Anthropic oauth 400 `invalid_grant` "Refresh token expired" (known env issue, not task-specific).