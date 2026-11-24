# CodeRabbit review — beads:foreman:foreman-ttc4i (run-3c8ece151ec208c88b12ae8d69459ed9, phase 3)

## Review engine

Ran from the worktree root, with `FOREMAN_BASE_BRANCH=main`:

```
coderabbit review --agent --base main
```

Round 1 and round 2 both exited 0 and completed (`"status": "review_completed"`). Raw
JSONL output kept outside the repo at `~/.foreman/tmp/ttc4i_cr_r1.out` and
`~/.foreman/tmp/ttc4i_cr_r2.out`. No authentication or PATH problem, so no
fallback path was taken.

## Rounds

**Round 1** — 1 finding received, 1 fixed, 0 declined.

| severity | file | line | finding | disposition |
| --- | --- | --- | --- | --- |
| major | `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | 147 | "Use the context supplied by `setup`." — the new test calls `base_ctx()`, a function the module never defines. | fixed |

Verified before acting: `grep -n base_ctx` over the file returned only line 147 (the
call site), and the module has a `setup` callback supplying `ctx` that every sibling
test in the same `describe` uses. The finding is not a style nit — the file did not
compile at HEAD. Reproduced on the committed state:

```
error: undefined function base_ctx/0 (expected ForemanServer.AgentRuntime.JidoHarness.SkillResolverTest to define such a function or ensure its imported name is correct)
│ (test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs:147)
** (CompileError) ... cannot compile module ForemanServer.AgentRuntime.JidoHarness.SkillResolverTest
```

**Round 2** — 0 findings received (`reviewedFiles`: `FIX_REPORT.md`, `PLAN.md`,
`skill_resolver.ex`, `skill_resolver_test.exs`). No `Critical`/`Major` left open, so
round 3 was not run.

## Fixed

- `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs:147`
  — the regression test added by phase 2 called an undefined `base_ctx/0`, so the whole
  test module failed to compile and the bead's guard had no running coverage. Changed
  the header to take the context the `setup` callback already provides
  (`test "a home the VM does not know is unverifiable", ctx do`) and dropped the
  `ctx = base_ctx()` line. Both assertions are untouched. The file now compiles and the
  test passes.

Not a CodeRabbit finding, reported so nothing is hidden: `FIX_REPORT.md` in this
run's report directory is an 86-byte truncated fragment of phase 2's narration
("Now Edit 3 — the test, inserted before the `agent directory` describe closes
(:136):"). `git log --all -- .../FIX_REPORT.md` shows it was committed exactly like that
in `276de7b6`, so there is no fuller version to restore. Phase 2's actual change is
recoverable from that commit's diff to `skill_resolver.ex` +
`skill_resolver_test.exs`, and `PLAN.md` is intact. Left as committed — rewriting
another phase's artifact is outside this phase's remit.

## Declined

None.

## Verification

| command | exit |
| --- | --- |
| `coderabbit review --agent --base main` (round 1) | 0 (1 finding) |
| `coderabbit review --agent --base main` (round 2) | 0 (0 findings) |
| `MIX_ENV=test mix test test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | 0 — 53 passed |
| `MIX_ENV=test mix test test/foreman_server/agent_runtime/jido_harness/` | 0 — 179 passed |
| `mix format --check-formatted` (both files in the run's diff) | 0 |
| `MIX_ENV=test mix compile --warnings-as-errors` | 0 |

`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test` was exported for
the mix commands (this repo's `claim_database!` needs it).

The new test is a real regression test, not a tautology: with the `is_binary(home)`
guard removed from `resolve_pi/2`, it fails with
`** (FunctionClauseError) no function clause matching in Path.type/1` (52/53 passed);
the guard was then restored via `git checkout --`.

Doc gate: no externally visible identifier was added, removed or renamed by this run —
`resolve_pi/2` is private and `SkillResolver.resolve/4`'s contract is unchanged. Grep of
`CLAUDE.md` (lines 800, 806, 820, 822 — `SkillResolver.resolve/4`, `:skill_home`),
`README.md` (no hits), `docs/user-guide.md:1935` (`:skill_home`) and
`docs/cli-reference.md` (no hits): all four files stay accurate, none needed edits — no
operator-visible change. `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md`
limitation (xl) still reads truthfully (point-in-time spec; per AGENTS.md left as written).

Uncommitted working-tree change: the one test-file edit above. Foreman commits this
phase's work.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs", "line": 147, "description": "The new HOME-unset regression test calls an undefined base_ctx/0, so the test module fails to compile and the guard has no coverage; fixed by using the context from setup.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "Two small files: one internal default swap from System.user_home!/0 to System.user_home/0 behind a guard in a private clause, and one test that now compiles and passes. 179 tests green in the touched directory, format and warnings-as-errors clean, no route, config key, CLI verb or event surfaced."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
