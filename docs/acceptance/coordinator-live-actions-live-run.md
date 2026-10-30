# Coordinator add_repo / schedule / setup proposal / usage: live run, 2026-10-30

Bead `foreman-fas1b` (C5, C10 setup proposal, C11 coordinator usage). Harness: `scripts/e2e/coordinator_live_actions.sh`
(own port 4830, own database, scratch git repos with local bare origins, own `br` databases; private claude HOME via
`claude_home.sh`; real coordinator provider). Run it with
`COORD_PROVIDER=claude COORD_MODEL=haiku devbox run -- bash scripts/e2e/coordinator_live_actions.sh`.

## Result

| Provider | Result |
|---|---|
| claude `haiku` (real CLI, private HOME, OAuth through the symlinked Keychains) | **PASS**: `passed=31 failed=0 unverified=0` (267 s) |
| pi `minimax/MiniMax-M2.7-highspeed` | **UNVERIFIED**: `pi --list-models` on this host lists no MiniMax model (only anthropic, litellm, openai, xai providers), so the harness records UNVERIFIED and stops. Run the same command with `COORD_PROVIDER=pi` on a host that has the model. |

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

- pi/minimax leg (above).
- An **invented quote** is not reproduced live: the real model never invented one, so the refusal of an unverified quote
  (`Policy.quote_verified?/2`) stays covered by tests only. The machine-turn refusal (source `mcp`) is live.
- **Cost unknown (null instead of 0)** is not reproduced: claude reports a cost on every turn. Covered by tests only.
- The tokens were compared with Foreman's own `CoordinatorUsageRecorded` events, not with the provider's transcript: claude's
  session files under the private HOME (175 files, output-token sum 6162) hold more than the coordinator turns (readiness
  probe, repair retries, other sessions), so they cannot be reconciled one to one with the 2913 recorded.
- The first harness run (before the 1b step) failed one assertion that expected "apply 1" to fix AGENTS.md; that was the wrong
  premise above, not a server defect. A later run failed on a harness bug (usage events summed over two projects); fixed.
