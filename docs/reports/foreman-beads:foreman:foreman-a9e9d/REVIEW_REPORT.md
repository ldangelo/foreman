

Phase 4 done.

**Reviewed**: `git diff main...HEAD` = 3 report artifacts (281 insertions), zero product code. Root `AGENTS.md` = rules source.

**Findings: 10 → 6 fixed, 2 declined, 2 open (major)**

Fixed:
- `REVIEW_CODERABBIT_REPORT.md` — clobbered to 17-line stub, no machine block; restored byte-identical from `315e3ec3` (sha256 match)
- `FIX_REPORT.md:4` — PR #953 is a different merged PR; branch has no PR → corrected
- `FIX_REPORT.md:25/:28/:106` — "tested here" + nonexistent SHA `6169c09c` → file came from `main` (`2fcddeef`/#487, 9 tests)
- `PLAN.md:10` — "HEAD `c209f8b4`" is the merge base, not head `2475a9fe` nor main tip `018da6b1`

Declined:
- carried `PLAN.md:25` (#955 counted as implemented-with-tests — still true)
- `FIX_REPORT.md` §6 fenced YAML ≠ `foreman.review_findings/1`; fix phase defines no machine block, only the last artifact is read → `:absent` expected

Open (human):
- bead's tests (title fallback, `## PR body`, template headings, path scrub) need sibling branches #955/#957/#959 + unpushed `foreman-p0b23` — cannot land here
- branch has no PR → work not retained

**Verification**: 125 tests pass (phase_pr_test, phase_pr_body_test, auto_pr_test) via `devbox run … mix test --warnings-as-errors` (exit 0); `ReviewFindings.read/1` on final report = `{:recorded, 10}` w/ 2 unresolved majors; `PrRisk.parse_judgement/1` = recorded LOW. Doc gate: no new identifiers; `CLAUDE.md:1229` already documents the marker format; README/user-guide/cli-reference no hits → no doc edit.

**State**: fixes uncommitted (Foreman commits). Only `docs/reports/foreman-beads:foreman:foreman-a9e9d/` touched — no lib/test/config path.

Operator note sent (`status: sent`), task comment added (`beads:foreman:foreman-a9e9d`). `ask_advisor` unavailable — Anthropic oauth `invalid_grant` (known env defect).