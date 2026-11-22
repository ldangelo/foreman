Phase 3 done.

## CodeRabbit review — `beads:foreman:foreman-jzycy`

**Engine**: coderabbit 0.9.6, `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`=main`, set → correct base). Round 1 exit 0 (3 minor findings), Round 2 exit 0 (0 findings) → stopped.

**Fixed**
1. `packages/foreman_server/lib/foreman_server/review/analyzer.ex:57` — comment cited a pinning test that didn't exist. Comment now quotes the exact title, and the test was added at `packages/foreman_server/test/foreman_server/review/analyzer_test.exs:844`: `"a run whose projection is already terminal is still reviewed, failed and cancelled alike"` (seeds run → applies `RunFailed`/`RunCancelled` → asserts projection already terminal → asserts review verdict `met` + manifest status).
2. `docs/reports/foreman-beads:foreman:foreman-jzycy/FIX_REPORT.md:1` — was the committed 33-byte junk `I'll start by reading the plan.`; rewritten with the real report.

**Declined** — `PLAN.md:57` "Reverse only the temporary event-list edit": stale, the plan's own proof step is self-reverting (`git checkout -- analyzer.ex`), it was executed, red run observed, file restored.

**Decision on record**: expectation (3) of `foreman-ws23g` (*no review for an already-terminal run*) is **rejected** — terminal failed/cancelled runs are reviewed on purpose (read-only `DetachedRun`, scratch cwd, outside Overwatch/worktree; `docs/user-guide.md:1114`). No production behaviour, config, or public identifier changed → doc gate: no edits needed in `CLAUDE.md`/`README.md`/`docs/user-guide.md`/`docs/cli-reference.md`.

**Verification**
- `MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors` → 42 passed, exit 0 (own DB `foreman_test_jzycy`; advisory lock forbids sharing `foreman_test`)
- `mix format --check-formatted` (both edited files) → exit 0
- proof run with `RunFailed RunCancelled` removed from `@terminal_events` → 38/42, exit 2 (new test fails → load-bearing), file restored
- report blocks parse: `ReviewFindings.read/1` → `{:recorded, ...}`, `PrRisk.parse_judgement/1` → `status: "recorded", level: "LOW"`

**Report**: `docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md` (5 sections + findings block: 2 fixed / 1 declined + risk judgement LOW). Fixes left uncommitted for Foreman. Kata issue `pes1` created + closed with the test command as evidence.

Note: `ask_advisor` unavailable again (Anthropic `invalid_grant`, refresh token expired) — no advisor review of this phase.