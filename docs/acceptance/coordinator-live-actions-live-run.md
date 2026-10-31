# Coordinator add_repo / schedule / setup proposal / usage: live run, 2026-10-30

Bead `foreman-fas1b` (C5, C10 setup proposal, C11 coordinator usage). Harness: `scripts/e2e/coordinator_live_actions.sh`
(own port 4830, own database, scratch git repos with local bare origins, own `br` databases; private claude HOME via
`claude_home.sh`; real coordinator provider). Run it with
`COORD_PROVIDER=claude COORD_MODEL=haiku devbox run -- bash scripts/e2e/coordinator_live_actions.sh`.

## Result

| Provider | Result |
|---|---|
| claude `haiku` (real CLI, private HOME, OAuth through the symlinked Keychains), 2026-10-30 script | **PASS**: `passed=31 failed=0 unverified=0` (267 s) |
| claude `haiku`, extended script (2026-10-31, see the last section) | **PASS**: `passed=41 failed=0 unverified=0` (482 s) |
| pi `minimax/MiniMax-M2.7-highspeed`, extended script (2026-10-31) | **PASS**: attempt 2 `passed=48 failed=0 unverified=0` (511 s); attempt 1 `passed=45 failed=0 unverified=1` (407 s), the one UNVERIFIED being a model that quoted the operator verbatim when asked to leave the quote out (a guard working, not a pass of the no-quote case) |

## What was observed (claude haiku)

1. **Setup proposal.** The first conversation message of a freshly registered project is `system/setup_proposal`, posted with
   no model turn (no `coordinator` usage row existed before the first turn).
   - A repository without AGENTS.md: the proposal lists `repo.agents_md_missing` but offers no `apply N` for it. Its fix is
     manual (`Recommendations.applicable?/1` is false), so "apply 1" correctly applied nothing: the coordinator answered
     "has no automatic fix", no AGENTS.md was written, no `apply_recommendation` was executed. **The bead's premise
     ("apply 1 applies the AGENTS.md fix") does not match the code**; the AGENTS.md fix cannot be applied by Foreman.
   - A repository with a `.beads` database registered with task provider `github`: the proposal offers
     `Reply "apply 1"` for `task_provider.wire_beads`; "apply 1" produced `[system notice] Applied setup recommendation
     task_provider.wire_beads.`, `foreman project recommend` no longer lists it, the project's task provider is `beads`, and
     `/setup` posted a second, fresh proposal without it.
2. **add_repo.** An operator chat turn asking to add `<scratch>/repo2` was `executed`: `foreman project repo list` shows it with
   `added_by: coordinator:<project>`. A machine turn (`foreman_project_message` over `/mcp`, source `mcp`; a model turn ran for
   it, `CoordinatorUsageRecorded` for its turn id) asking to add `repo3` registered nothing.
3. **schedule.** An operator turn "every 15 minutes, workflow edit, prompt ..." created the schedule: `foreman project
   schedule list` shows it with `auto_approve: false` (project `--coordinator-propose-before-start=true`). "every 1 minute" was refused
   and the model's reply in the conversation carries the reason: `I did not run schedule: the schedule spec is not valid
   (every: below_minimum); use an interval such as 30m, 6h or 1d, or a 5-field cron expression in UTC ...`; no 1 minute
   schedule exists.
4. **Usage.** After 5 provider turns of project 1: `foreman usage --by role` lists `coordinator` input 10, output 2913,
   cache-read 68127, cache-write 95007, total 2923, cost 0.0211. Input, output and total equal the sum of the project's five
   `CoordinatorUsageRecorded` events (read from the event store); the project total equals that row; `--by thread` does not
   list the coordinator.

## UNVERIFIED / limits

- ~~pi/minimax leg~~ Run 2026-10-31 (last section): `pi --list-models` on this host now lists `MiniMax-M2.7-highspeed`, `MiniMax-M3`, `MiniMax-M2.7` and `MiniMax-M3.1-Flash`, so the old "no MiniMax model" blocker is gone.
- ~~An invented quote is not reproduced live~~ Reproduced 2026-10-31 on both providers, but **the alteration is instructed by the operator in the chat message, not hallucinated by the model unprompted** (last section). A model that invents a quote on its own initiative has not been observed.
- **Cost unknown (null instead of 0)** is still not reproduced live: both providers report a cost on every turn (pi's `cost(0)` is `0.0`, never nil). Covered by tests only.
- The tokens were compared with Foreman's own `CoordinatorUsageRecorded` events, not with the provider's transcript: claude's
  session files under the private HOME (175 files, output-token sum 6162) hold more than the coordinator turns (readiness
  probe, repair retries, other sessions), so they cannot be reconciled one to one with the 2913 recorded.
- The first harness run (before the 1b step) failed one assertion that expected "apply 1" to fix AGENTS.md; that was the wrong
  premise above, not a server defect. A later run failed on a harness bug (usage events summed over two projects); fixed.

## 2026-10-31: the pi leg, the invented quote, the no-quote case and pi usage against pi's own stream (`foreman-fas1b`)

Script changes (`scripts/e2e/coordinator_live_actions.sh`, new shim `scripts/e2e/coordinator_live_actions/pi-capture.sh`):
a step 2b with two **invented-quote** attempts (the operator asks the coordinator to write `please register the fifth repository`
with underscores in the `quote` field), a **no-quote** step (two attempts: the operator asks it to leave `quote` out) and a
**positive control** (the same request asking it to quote the operator's words); a `dump_events` helper; and, for pi, a transparent `pi`
shim first on the server's PATH that tees the stdout of every `pi --mode json` run to `$WORK/pi-capture/` and keeps pi's exit status.
A coordinator turn runs pi with `no_session: true`, so there is no pi session file: the shim is the only independent record of what pi
itself reported. Whether the quote is verbatim is judged by the harness restating `Policy.quote_verified?/2` (lowercase, collapse whitespace,
trim, substring) on the recorded `CoordinatorActionRecorded` params; a model that quotes verbatim is recorded UNVERIFIED, never a pass.

Commands: `COORD_PROVIDER=pi COORD_MODEL=minimax/MiniMax-M2.7-highspeed devbox run -- bash scripts/e2e/coordinator_live_actions.sh` (pi attempt 1:
`passed=45 failed=0 unverified=1 wall=407s`; attempt 2 after a stronger no-quote phrasing: `passed=48 failed=0 unverified=0 wall=511s`) and
`COORD_PROVIDER=claude COORD_MODEL=haiku ...` (`passed=41 failed=0 unverified=0 wall=482s`). Provider spend: roughly $0.03 to $0.06 per pi leg
(from the recorded usage) and about $0.04 for the claude coordinator turns.

Observed on both providers:

1. **Invented quote.** The model emitted `add_repo` with `quote: please_register_the_fifth_repository`, which is not in the operator's message. The
   action was recorded `rejected` with the reason `this needs the operator's exact words (quote) from their message`; the conversation carries
   `I did not run add_repo: ...`; the repository was not registered. The positive control (same request, "Quote my words.") was `executed`
   and `foreman project repo list` shows it with `added_by coordinator:<project>`.
2. **No quote.** `quote: null` was `rejected` with the same exact-words reason and nothing was registered. With the first, weaker phrasing the
   model quoted anyway and the action was `executed` (correct guard behaviour, so that attempt is UNVERIFIED for the no-quote case); the stronger
   phrasing produced `quote: null` on both providers.
3. **pi usage against pi's own raw stream (pi leg, attempt 2).** 10 `CoordinatorUsageRecorded` events and 10 captured pi runs (37 assistant messages): the sum
   of the `usage` pi itself printed (input 50878, output 8554, cacheRead 156047, cacheWrite 0, total 215479, cost 0.060419) equals the sum of
   the recorded events field by field. Attempt 1 matched on the totals too (9 events against 10 captured runs: the tenth run was not investigated).
   pi's `totalTokens` includes cache reads, while claude's `total_tokens` is input + output only: the same field means different things per provider
   (claude leg: `usage --by role` coordinator total 7008, 9 turns, cost 0.0419).
4. **Other pi results.** "apply 2" on the AGENTS.md item was refused honestly (`not_appliable`, nothing written); "apply 1" on `task_provider.wire_beads`
   was applied, `recommend` no longer lists it and `/setup` posted a fresh proposal; the machine turn (source `mcp`) added nothing; the 15 minute
   schedule was created with `auto_approve: false`; the 1 minute schedule was refused (`below_minimum`) with the reason in the conversation.
   pi coordinator turns used pi's read-only tools (up to 12 tool calls in one turn): an observation, not a failure.

Not proven: a model inventing a quote unprompted (here the operator instructs the change); a null cost (tests only); the claude token numbers against
claude's own transcript (the private HOME's session files hold more than the coordinator turns, as above). No Elixir code changed.
