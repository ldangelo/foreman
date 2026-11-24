Phase done.

**CodeRabbit review — 4 rounds, exit 0 each**
- 19 findings: 18 fixed, 1 declined
- R1: 10 (2 crit, 5 maj, 3 min) — all fixed: builder didn't compile (interpolating regex, unbound `remaining`), no AutoPR caller, missing event/state fields, tuple leak, accumulator mismatch, invented subject, missing heading validation, bad overflow/clamp
- R2: 5 min — fixed: MCP keys now schema-derived, failed `git log` no longer looks like "no commits", commits from resolved PR head, malformed headings no longer dropped, phase-PR limitation documented
- R3: 1 crit **declined** (false positive: `PrBody` module exists but was untracked ⇒ CodeRabbit's tracked-only diff missed it; `mix compile --warnings-as-errors` exit 0) + 1 min fixed (one shared typed helper `ProjectSettings.pr_body_headings/1` → `{:malformed, _}` refused at `PrBody.build/2`)
- R4: 2 min — fixed: user guide still claimed "body is exactly the task description" (now qualified); bare map → `AutoPR.PrContent` `@enforce_keys` struct

**Verification**: `mix format` clean; `MIX_ENV=test mix compile --warnings-as-errors` exit 0; 126 + 74 tests passed (private DB `foreman_test_p0b23` — standard `foreman_test` advisory-locked by run-4aa2a5bd). Doc gate: `pr_body_headings` in CLAUDE.md/user-guide/cli-reference; README lists no project settings → no edit.

**Report**: `docs/reports/foreman-beads:foreman:foreman-p0b23/REVIEW_CODERABBIT_REPORT.md` — both JSON blocks parsed and validated (19 entries: 18 fixed / 1 declined; risk MEDIUM). Fixes left uncommitted for Foreman. Inbox note + task Work Log comment sent (both OK).