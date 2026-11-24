Phase 3 (coderabbit-review) done for `foreman-vbfmo.12`.

**Round 1** — `coderabbit review --agent --base main` (exit 0): 2 minor findings, both real.
1. `context.ex:138` — cancelled had no own clause → fell through to `:idle`, or `:ready_for_review` once a `last_report` existed (that clause sits above status clauses, so it also dodged card eviction). **Fixed**: added `def card_state(%Thread{status: "cancelled"}), do: :resolved` above the `last_report` clause.
2. `context_test.exs:363` — asserted the `:idle` fallback, not the required disposition. **Fixed**: now asserts `:resolved` for cancelled, plus a cancelled-with-`last_report` case to pin clause ordering.

**Round 2** (exit 0): 1 minor finding on the phase-1 `REVIEW_CODERABBIT_REPORT.md` — its claim that cancelled threads still inflate "active threads now" is stale (`limits_section/1` counts only `:working`/`:waiting_on_you`). Corrected by rewriting the report; no code change. No Critical/Major ⇒ stopped, no round 3.

**Verification** (devbox, `DATABASE_URL=…:55432/foreman_test`): `mix compile --warnings-as-errors` exit 0 · `mix test test/foreman_server/coordinator/context_test.exs` → 17 passed · `mix test test/foreman_server/coordinator` → 219 passed · `mix format --check-formatted` on both edited files exit 0.

**Doc gate**: no externally visible identifier added/renamed; only `waiting_on_you` hits describe `Overview.Group.classify/1` (untouched) ⇒ none of CLAUDE.md / README.md / docs/user-guide.md / docs/cli-reference.md needed edits.

**Left out deliberately** (reported in Declined, not edited): the prior phase's `FIX_REPORT.md` is 169 B of tool-error junk and `PLAN.md` names functions absent from this code version (`Context.summary/1`, `groups.done`) — a review phase shouldn't falsify another phase's record; `context_contract_test.exs:29` keeps `"cancelled" → :waiting_on_you` as a budget/eviction fixture, still green.

Fixes left uncommitted for Foreman. Report: `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md` (3 findings, all `fixed`; risk `LOW`). `ask_advisor` unavailable again — Anthropic oauth refresh 400 `invalid_grant`.