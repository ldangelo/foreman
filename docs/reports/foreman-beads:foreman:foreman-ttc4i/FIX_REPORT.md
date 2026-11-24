# FIX_REPORT — foreman-ttc4i

> Rewritten in the repo-rules review phase. The fix phase committed an 86-byte
> tool-error fragment here (`Now Edit 3 — the test, inserted before the
> `agent directory` describe closes (:136):`), which carried none of the six
> sections `packages/foreman_server/priv/defaults/workflows/prompts/fix.md`
> requires. This report states what the run actually did.

## Root cause

`ForemanServer.AgentRuntime.JidoHarness.SkillResolver.resolve_pi/2`
(`packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex:123`)
took the home directory with
`Keyword.get_lazy(opts, :home, &System.user_home!/0)`. `System.user_home!/0`
raises when the VM has no home, and a caller that passed `home: nil` reached
`Path.type/1` and raised `FunctionClauseError`. `resolve_pi/2`'s
`else _ -> :unverifiable` matches values, not exceptions, so the raise escaped
into `ForemanServer.Workflow.RunExecutor.kickoff_skill_preflight/1`
(`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:563`) and
killed the run at kickoff instead of recording a verdict. PR 8 removed the
catch-all rescue (AGENTS.md §5.2), so nothing absorbed the raise.

## Change

- `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex`
  — `resolve_pi/2` takes the home with `System.user_home/0` (no raise) and
  guards it with `home when is_binary(home)` in front of the existing
  `:absolute <- Path.type(home)` clause, so an absent, `nil` or relative home
  answers `:unverifiable` — the same verdict as every other unknown input.
- `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex`
  (moduledoc) — the `:home` option documents the new default and the
  `:unverifiable` answer instead of the raising default.
- `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`
  — new test "a home the VM does not know is unverifiable": the skill is seeded
  in the agent dir, the same skill is asserted `:available` under the usable
  home, and `:unverifiable` under a `nil` home, for a present and an absent
  skill.

## Deviations from the plan

- The plan's test body seeded the skill with
  `put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")`; the fix phase
  shipped the test without that seed, so the `:unverifiable` assertion could
  not distinguish an unusable home from an absent skill. The seed and the
  `:available` contrast were restored in the repo-rules review phase.
- The plan's "Failing check first" was not run before the edit in the fix
  phase. The regression was proven afterwards in the repo-rules review phase by
  restoring the pre-fix resolver (`git show main:…/skill_resolver.ex`): the new
  test fails with `** (FunctionClauseError) no function clause matching in
  Path.type/1` and the file reports `52/53 passed`.
- The fix phase replaced this run's `PLAN.md` with a 10-line summary of its own
  edits, which fix.md forbids ("Do not commit `PLAN.md` and do not edit it.").
  The 134-line plan was restored in the repo-rules review phase.
- The test's name differs from the plan's ("a home that is nil is
  unverifiable" → "a home the VM does not know is unverifiable"). The name is
  the fix phase's and was kept: it describes the input rather than the value.
- The plan's §5 verification also named
  `test/foreman_server/workflow/run_executor_skill_preflight_test.exs`; that
  file is unchanged and was run green (18 passed) rather than skipped.

## Tests

- `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`
  — "a home the VM does not know is unverifiable": failing before the fix
  (`FunctionClauseError in Path.type/1`), passing after.
- No other test file was changed.

## Local verification

- `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`
  → `Result: 53 passed`, exit 0.
- `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_skill_preflight_test.exs`
  → `Result: 18 passed`, exit 0.
- `mix format --check-formatted lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`
  → exit 0.
- `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors'`
  → exit 0, `Result: 9255 passed (8 properties, 9247 tests), 11 excluded`, 822.1 s.
- Regression probe with the pre-fix resolver in place → `Result: 52/53 passed`,
  `** (FunctionClauseError) no function clause matching in Path.type/1` at
  `skill_resolver_test.exs:148`; the fixed resolver was restored afterwards
  (`git checkout --`) and compared byte-identical to the fixed file.
- `mix test` needs the event store even for a single file: the `test` mix alias
  calls `ForemanServer.MixProject.claim_database!/2`, so a `DATABASE_URL` that
  accepts the credentials is required (`foreman-postgres` on localhost:55432).

## Follow-ups

- `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` limitation (xl)
  (line 645) still records only the `project_env/1` raise. The bead asked for
  it to be extended to this raise; AGENTS.md keeps point-in-time spec claims
  as written, and the TRD's own version history says a superseded claim gets a
  forward-pointer in the task text instead. The TRD was left alone.
- `docs/decisions/phase-0-durable-execution-engine.md:248` still lists this bead
  as `INDEPENDENT` with the defect described. The rows for other beads were not
  rewritten when those beads were fixed, so this row was left alone.
