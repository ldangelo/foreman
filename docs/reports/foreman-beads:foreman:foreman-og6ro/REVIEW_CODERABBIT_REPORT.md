Phase 3 (`coderabbit-review`) complete.

**Review engine** — `coderabbit review --agent --base main` (coderabbit 0.9.6), 4 rounds, exit 0 each, `status: review_completed`.

**Findings** — 6, all minor, all about the run's own report artefacts (branch carries zero code vs `main` — only `PLAN.md` + `FIX_REPORT.md`, 49 insertions):

Fixed 3:
- `…/PLAN.md:9` — the plan's key check was `grep -rn "a|b|c"`; BRE treats `|` literally, so the "zero matches" verdict was never tested. Now `grep -rnE`; re-ran → exit 1, zero matches, so the Blocked verdict still holds.
- `…/PLAN.md:5` — "Plan: `docs/reports/…/PLAN.md` (84 lines)" pointed at a file that now holds phase 1's 31-line summary. Now points at `git show 912dd597:'docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md'`.
- `…/FIX_REPORT.md:14` — claimed the tree copy matched the committed plan byte-for-byte; false. Corrected, plus the restore command.

Declined 1: rename the colon-bearing report dir — the path is minted by `RunExecutor.project_reports_dir/1` (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:2490-2491`) and consumed via `{task.projectReportsDir}` in every bundled workflow; renaming from inside a run orphans its own artefacts. Real fix is a separate task in that function.

**Verification** — no test command (no `.ex`/`.exs`/`.go` changed); no formatter (`.formatter.exs` covers no `**/*.md`). Both machine-read blocks validated against a python3 re-implementation of `extract_block/3` — `mix run` can't execute the real parsers here, `packages/foreman_server/deps` is empty. Findings block 1416 B / 4 entries, `ReviewFindings.unresolved/1` = 0. Judgement block 625 B, `level: MEDIUM` (raised from LOW: a docs-only diff that delivered none of the bead's tests reads as delivered work — signalling risk, not technical).

**Caveats** — `ask_advisor` unavailable (Anthropic oauth `400 invalid_grant` "Refresh token expired"), so the risk level rests on my reasoning alone; the report says so. `foreman_inbox_send`/`foreman_task_add_comment`/`ask` unavailable, so no operator notes were sent. kata 5q3f labelled `needs-review` and left OPEN — bead `foreman-og6ro` remains unimplemented by design (the code under test lives only on unmerged PR #942, which already ships `run_executor_origin_base_test.exs`). Fixes left uncommitted.