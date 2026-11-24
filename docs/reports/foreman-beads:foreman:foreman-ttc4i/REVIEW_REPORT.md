# REVIEW_REPORT — repo-rules review — foreman-ttc4i

## Review engine

Reviewer: the `repo-rules` reviewer (repository-rules review phase, phase 4 of
the `fix` workflow), reviewing this run's own work against the repository's own
rules — `AGENTS.md` (rules, documentation gate, §5 typed boundaries) and the
bundled workflow contracts under `packages/foreman_server/priv/defaults/`.

Diff range reviewed: `git diff main...HEAD` (three-dot), where `main` is
`$FOREMAN_BASE_BRANCH`. Merge-base `0988b0717dec65e0bdacf1a9819c5f285414cdaa`,
HEAD `169b8d4a96f1d10ea52a05e20516de2c7a9c8e90`. Five files in range:

- `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex`
- `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`
- `docs/reports/foreman-beads:foreman:foreman-ttc4i/PLAN.md`
- `docs/reports/foreman-beads:foreman:foreman-ttc4i/FIX_REPORT.md`
- `docs/reports/foreman-beads:foreman:foreman-ttc4i/REVIEW_CODERABBIT_REPORT.md`

The previous phase's report
(`docs/reports/foreman-beads:foreman:foreman-ttc4i/REVIEW_CODERABBIT_REPORT.md`)
has **no machine-readable findings block** — `awk '/FOREMAN_REVIEW_FINDINGS_START/,0'`
on it prints nothing; the file is prose only, although its own closing lines
claim a findings block and a risk judgement block. Its single finding (the
undefined `base_ctx/0` `CompileError` in the new HOME-unset test, fixed in
phase 3) is therefore carried forward from that prose, with `source`
`coderabbit`.

Progress notes (`foreman_inbox_send`, `foreman_task_add_comment`) are not
exposed in this phase, so no operator notes were sent.

## Findings

| # | Severity | Path | Finding | Disposition |
| --- | --- | --- | --- | --- |
| R1 | major | `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | The new HOME-unset test never seeded the skill, so its `:unverifiable` assertion could not distinguish an unusable home from an absent skill. | fixed |
| R2 | minor | `docs/reports/foreman-beads:foreman:foreman-ttc4i/FIX_REPORT.md` | The fix phase's report was an 86-byte tool-error fragment instead of the six sections `fix.md` requires. | fixed |
| R3 | minor | `docs/reports/foreman-beads:foreman:foreman-ttc4i/PLAN.md` | The fix phase replaced the 134-line plan with a 10-line summary — forbidden by `fix.md`, and it contradicted the file's own "(134 lines)" claim. | fixed |
| R4 | nitpick | `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` | The bead asks to extend TRD limitation (xl) to this raise. | declined |
| C1 | major | `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | The phase-2 test called an undefined `base_ctx/0`, so the module did not compile and the new guard had zero coverage. (carried from the previous phase) | fixed (in phase 3) |

## Fixed

**R1 — `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`**

- What was wrong: the test shipped by the fix phase asserted
  `resolve("fix-issue", home: nil) == :unverifiable` without ever creating the
  `fix-issue` skill. An absent skill also answers `:unverifiable` here, so the
  assertion passed for the wrong reason and would have passed even if the
  `home: nil` guard were deleted. The plan's own test body seeded the skill
  with `put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")`; the shipped
  test dropped that line.
- What changed: the test now seeds the skill in the agent dir and contrasts the
  two homes — `resolve("fix-issue", ctx.opts) == :available` under the usable
  home, `resolve("fix-issue", home: nil) == :unverifiable` under the `nil`
  home, and the absent skill still `:unverifiable`. The comment above the test
  states why the seed exists.
- Proof it now bites: with the pre-fix resolver restored from `main`
  (`git show main:…/skill_resolver.ex`) the file reports `52/53 passed` and
  the new test fails with `** (FunctionClauseError) no function clause matching
  in Path.type/1` (the `Path.type(nil)` raise). The fixed resolver was
  restored afterwards and byte-compared.

**R2 — `docs/reports/foreman-beads:foreman:foreman-ttc4i/FIX_REPORT.md`**

- What was wrong: the fix phase committed an 86-byte capture of a tool error —
  the whole file read `Now Edit 3 — the test, inserted before the `agent
  directory` describe closes (:136):`. `fix.md` requires the report to cover
  six sections (Root cause / Change / Deviations from the plan / Tests / Local
  verification / Follow-ups) and to state what was changed; nothing in the diff
  documented the change.
- What changed: the report was rewritten with those six sections, naming the
  files, the raise that escaped `resolve_pi/2`'s `else _ -> :unverifiable`
  into `RunExecutor.kickoff_skill_preflight/1`, the deviations from the plan
  (the dropped seed, the failing check not run before the edit, the plan
  overwrite), the tests, the local verification commands, and the two follow-ups
  that were deliberately left undone. A leading note records that the report was
  rewritten in this review phase and what the fix phase had committed.

**R3 — `docs/reports/foreman-beads:foreman:foreman-ttc4i/PLAN.md`**

- What was wrong: the fix phase overwrote the 134-line plan (commit `40c1d78a`)
  with a 10-line summary of its own edits. `fix.md` states "Do not commit
  `PLAN.md` and do not edit it", and the replacement's last line still claimed
  the artifact was "134 lines".
- What changed: the plan was restored from `40c1d78a`
  (`git show 40c1d78a:…/PLAN.md`), so the artifact matches its own claim and
  the plan the fix phase was bound to implement is the one in the tree.

## Declined

**R4 — `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:645`**

- The finding: the bead asks that TRD limitation (xl) — which today records
  only the sibling `project_env/1` raise — be extended to cover this bead's
  raise.
- The reason: `AGENTS.md` states that `docs/TRD/*` files are point-in-time
  specs whose claims stay as written, and the TRD's own version history says
  superseded claims get a forward-pointer in the task text instead of a
  rewritten row. The limitation list has no entry for this raise to extend
  (the entry for it lives in
  `docs/decisions/phase-0-durable-execution-engine.md:248`, whose rows for
  other beads were likewise not rewritten when those beads were fixed).
  Editing the TRD here would be a change to a point-in-time spec, not a
  reconciliation of documentation the diff adds or renames.

## Verification

| Command | Result |
| --- | --- |
| `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | `Result: 53 passed`, exit 0 |
| `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_skill_preflight_test.exs` | `Result: 18 passed`, exit 0 |
| `mix format --check-formatted lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` | exit 0 |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors'` (AGENTS.md's gate) | exit 0 — `Result: 9255 passed (8 properties, 9247 tests), 11 excluded`, 822.1 s |
| Regression probe: pre-fix resolver (`git show main:…/skill_resolver.ex`) in place, same test file | exit 2 — `** (FunctionClauseError) no function clause matching in Path.type/1` (`lib/path.ex:249` ← `skill_resolver.ex:128` ← `skill_resolver_test.exs:153`), `Result: 52/53 passed`; the fixed resolver was restored with `git checkout --` and `git status` shows the file identical to HEAD |
| `git diff main...HEAD` re-read after the fixes | no new violation introduced: the code change is unchanged from phase 2, the test change adds the seed and the `:available` contrast only, and the two artifact rewrites are documentation of what the diff already does |

Documentation gate: the diff adds, removes and renames no externally visible
identifier — no route, command/event type, MCP tool, CLI verb, env var, config
key, workflow or prompt name. `grep` for `SkillResolver`, `user_home`,
`:skill_home` in `CLAUDE.md`, `README.md`, `docs/user-guide.md` and
`docs/cli-reference.md` returns no stale reference to the old raising default,
so none of those four files needed edits; `docs/lessons/executor-isolation-and-vfs.md`
documents the three verdicts and never claimed a raise. The two files that did
need reconciliation are the run's own artifacts (`PLAN.md`, `FIX_REPORT.md`),
fixed above.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs", "line": 147, "description": "The new HOME-unset test never seeded the skill, so its :unverifiable assertion could not distinguish an unusable home from an absent skill.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-ttc4i/FIX_REPORT.md", "line": 1, "description": "The fix phase's report was an 86-byte tool-error fragment instead of the six sections the fix workflow prompt requires.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-ttc4i/PLAN.md", "line": 1, "description": "The fix phase replaced the 134-line plan with a 10-line summary, which the fix workflow prompt forbids and which contradicted the file's own line-count claim.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md", "line": 645, "description": "The bead asks to extend TRD limitation (xl) to this raise, but AGENTS.md keeps point-in-time spec claims as written.", "disposition": "declined", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs", "line": 147, "description": "The phase-2 test called an undefined base_ctx/0, so the test module did not compile and the new is_binary(home) guard had zero coverage.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change turns a raising path in SkillResolver.resolve_pi/2 into the typed :unverifiable verdict the resolver already uses, so a server started without HOME records a verdict instead of crashing the run at kickoff; the code edit is small and contained, but it alters a shared resolver used by every run's skill preflight, which is why the seeded regression test and the pre-fix failure probe were run rather than a green build alone."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
