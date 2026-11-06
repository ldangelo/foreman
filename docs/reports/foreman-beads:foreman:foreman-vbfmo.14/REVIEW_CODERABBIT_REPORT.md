Phase 6 complete.

**CodeRabbit review: ran, found nothing to review — because this run has zero code changes.**

Evidence:
- `FOREMAN_BASE_BRANCH=main` (set, so no stop-condition); HEAD `4ee1b417` == `merge-base` == `FOREMAN_SOURCE_REVISION`; `git diff --shortstat main...HEAD` empty.
- `coderabbit review --agent --base main` → exit 0, `{"status":"review_skipped","findings":0,"message":"No changes detected"}`. Corroborated with `--include-untracked` and `--committed` (same result). Engine authenticated, v0.9.2.
- 1 round; stopped early (no Critical/Major). Rounds 2–3 skipped deliberately — unchanged tree, and only 10 of 10 rolling-hour reviews left.
- No fixes, no declines, no test/formatter run: narrowest-test rule yields nothing when no file changed.

Root cause is upstream, not a code defect: the run's title (ask→Telegram/Slack operator-question bridge) doesn't match the delivered `FOREMAN_SOURCE_PRD_PATH` (`PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`, already merged at this base as #833/#834), so phases 3 and 5 correctly halted and produced no commits. Phases 1–2 also returned junk (`phase-2.md` is a pi greeting).

Report at the artifact path (129 lines, untracked dir left for Foreman to commit), with one Major unresolved finding naming the PRD/title mismatch as the operator action: fix the PRD pointer and re-run phases 1–4, or correct the title and abandon.

Note: `foreman_inbox_send` / `foreman_task_add_comment` are not exposed in this phase, so this artifact is the only status channel — no escalation path exists here (`ask_advisor` model unresolvable, `contact_supervisor` subagent-only).