Phase 3 (`coderabbit-review`) is complete.

## What ran
3 rounds of `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`FOREMAN_BASE_BRANCH=main`, verified non-empty) against the working tree — CodeRabbit CLI 0.9.7, the same engine as the PR bot. **6 findings received, 6 fixed, 0 declined.**

## The one that mattered
`run_executor_command_test.exs:791` (**major**): phase 2 added `assert delivered["PI_SUBAGENT_CHILD"] == "1"` directly above the pre-existing assertion that *every* delivered env key starts with `FOREMAN_`. Mutually unsatisfiable — red even when the feature worked. Now an explicit allowlist naming that single key, so the test still rejects unrelated env leakage. Verified it bites.

## The substantive one
Findings 2–5 were documentation, and they were right: the guide, PLAN.md, `docs/lessons/…` and the `run_executor.ex` comment all claimed the marker also stands down `advisorCompletionGate` / `advisorPlanGate` / `advisorBlockOnBlocked`. **That premise — taken from the bead text itself — is false.** I read `pi-advisor-flow/dist/index.js` to check rather than trusting the task: `isMarkedSubagent` at `:288` gates *only* the model/effort override; the three advisor gates are plain config booleans, not keyed on it. All four docs corrected. Also fixed: PLAN.md's doc-gate step exempted three of four gate files (self-contradictory), and `README.md` / `docs/cli-reference.md` lacked the new env key.

Two consequences worth your attention, now stated in code and docs: the marker **also unregisters `pi-subagents`**, so a phase agent cannot spawn pi subagents — which is what buys you the guarantee that a phase runs on the model Foreman resolved, not what an activation hook guessed. And if you want advisor behavior off for Foreman runs, that's the extension's config, not the env var.

## Validation
44 + 9 + 140 tests green, `mix format --check-formatted` clean, `go build`/`go vet`/`go test` clean including `usage_drift_test.go` after the `docs/cli-reference.md` edit. I did not eyeball the machine-read markers — `ReviewFindings.read/1` returns `{:recorded, …}` with 6 findings all `:fixed`, and `PrRisk.parse_judgement/1` returns `MEDIUM`, `defect: nil`. Risk is MEDIUM because the change alters the runtime of every Foreman-launched pi phase.

Kata `4v9y` closed with test evidence. 9-file diff left **uncommitted** for Foreman.

## Two things I did not paper over
- Phase 2 committed `FIX_REPORT.md` as a 63-byte fragment, not the six sections `fix.md` requires. Left untouched (it's that phase's artifact, and the next phase audits the committed diff) but flagged in the Declined section and in the operator note — so nobody reads silence as a clean record.
- `ask_advisor` failed again on `invalid_grant: Refresh token expired`, so the completion review has no independent check. Needs re-auth.