Phase 4 complete. Fixes are uncommitted, as required.

## Review engine
Diff: `git diff 796c888c75c4f5a6dbf33b09027d31fea9af7b1f...a441468a` (`FOREMAN_BASE_BRANCH=main` = merge-base). 5 files, +312/−0 — 3 new phase reports, `analyzer.ex` (+9, comment only), `analyzer_test.exs` (+35, one test). Rules: `AGENTS.md` + `CLAUDE.md` + touched-file idioms. Previous phase's `REVIEW_CODERABBIT_REPORT.md` findings block was readable → all 3 carried forward.

## Fixed (2)
- `docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md` — committed at `HEAD` with **no** machine-read findings or risk block and a junk first line `Phase 3 done.`, while its own prose claimed `ReviewFindings.read/1 → {:recorded,…}` and `PrRisk.parse_judgement/1 → recorded/LOW`. `CLAUDE.md` requires both blocks. Restored verbatim from `137c7c37`, dropped the junk line, restored the trailing newline.
- `packages/foreman_server/lib/foreman_server/review/analyzer.ex:52-63` — comment asserted the reviewer "is a read-only `DetachedRun`". `review/evaluator/agent.ex:152-157` says `sandbox_mode: :read_only` is not honoured by every provider and the scratch cwd is the actual guarantee. Comment now says a `DetachedRun` in a scratch cwd outside any git work tree + the caveat. No code change.

## Declined (2)
- carried `coderabbit` `PLAN.md:57` (proof step edits `@terminal_events`) — self-reverting proof sketch, delivered as the committed test instead.
- own `analyzer.ex:60` (`docs/user-guide.md:1114` pointer drifts) — file:line pointers are an established `lib/` convention, accurate today (`:1113-1116`), and the stable section title is cited alongside.

## Verification (all exit 0)
- `MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors` → 42 passed, 0 failures; ProjectionLeakGuard clean (own DB `foreman_test_jzycy`)
- `mix format --check-formatted` (both edited Elixir files), `mix credo --min-priority higher` (no issues, 1490 files), `mix doctor --raise` (0 failed modules)
- artifact re-read through the repo's own readers: `ReviewFindings.read/1` → recorded, 6 findings (3 `coderabbit` fixed/fixed/declined + 3 `repo-rules` fixed/fixed/declined); `PrRisk.parse_judgement/1` → recorded LOW, 392-char rationale
- doc gate: no identifier added/removed/renamed → `CLAUDE.md`/`README.md`/`docs/user-guide.md`/`docs/cli-reference.md` needed no edits (`grep docs/reports` → no hits; no CHANGELOG)

Report at `docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_REPORT.md`, risk `LOW`. Operator note sent (`msg_ULMIxIZaP4maN0GvCRYlYw`); kata `tm7a` created and closed. `ask_advisor` remains unavailable (Anthropic `invalid_grant`) — no completion review obtained.