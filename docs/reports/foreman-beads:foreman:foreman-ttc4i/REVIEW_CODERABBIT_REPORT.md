Phase 3 done.

## CodeRabbit review — foreman-ttc4i

**Engine:** `coderabbit review --agent --base main` (`FOREMAN_BASE_BRANCH=main`) — round 1 exit 0 (1 finding), round 2 exit 0 (0 findings). Stopped at 2 rounds per contract (no Critical/Major left).

**Round 1 finding (major) — fixed**
`packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs:147` — phase 2's new HOME-unset test called an undefined `base_ctx/0`, so the whole test module **did not compile** (reproduced: `CompileError`), leaving the `is_binary(home)` guard with zero coverage. Fixed: `test "a home the VM does not know is unverifiable", ctx do`, dropped the `base_ctx()` line, assertions untouched.

**Declined:** none.

**Verification**
- `mix test .../skill_resolver_test.exs` → 53 passed
- `mix test test/foreman_server/agent_runtime/jido_harness/` → 179 passed
- `mix format --check-formatted` → 0; `mix compile --warnings-as-errors` → 0
- Negation probe (earlier): dropping the `is_binary(home)` guard makes the new test fail with `FunctionClauseError in Path.type/1` ⇒ test is not a tautology
- Doc gate: no externally visible identifiers changed; greps of CLAUDE.md / README.md / docs/user-guide.md / docs/cli-reference.md for `SkillResolver`, `user_home`, `:skill_home` → all four stay accurate, **zero edits needed**
- TRD limitation (xl) about `project_env/1` left as written (point-in-time spec)

**Report:** `docs/reports/foreman-beads:foreman:foreman-ttc4i/REVIEW_CODERABBIT_REPORT.md` — 5 sections + findings block (`reviewed: true`, 1 entry, major/fixed/coderabbit) + risk judgement block (`LOW`). Both JSON blocks parsed locally; each marker line appears exactly once, outside fences.

**Notes**
- Phase 2's `FIX_REPORT.md` is an 86-byte truncated fragment committed as-is in `276de7b6`; no fuller version exists in git. Left unrewritten (other phase's artifact) but documented in the report prose.
- `foreman_inbox_send` / `foreman_task_add_comment` not exposed in this phase → no operator notes sent.
- kata issue `2qwg` created, claimed, closed with the test command as evidence.
- `ask_advisor` unusable again (Anthropic oauth 400 `invalid_grant` — operator must re-auth).
- Fixes left **uncommitted** for Foreman to commit.