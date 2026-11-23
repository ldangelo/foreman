Phase 4 (repo-rules review) complete.

**Artifact**: `docs/reports/foreman-beads:foreman:foreman-og6ro/REVIEW_REPORT.md` (untracked, uncommitted — Foreman commits it).

**Diff reviewed**: `git diff main...HEAD` (FOREMAN_BASE_BRANCH=main, non-empty) → 3 markdown files, 65 insertions, 0 deletions, **zero** code files.

**Findings (2, both `open`, nothing fixed)**
1. **major** — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4456`: the bead is unimplemented. `resolve_declared_base/2` (4447-4458) still ends in `resolve_revision(project_root, "HEAD")`; all four identifiers the bead names (`base_ref_policy`, `resolve_origin_base`, `fetch_origin_base`, `__resolve_provisioned_base_for_test__`) grep empty across lib/test/CLI. Writing the tests here would be a failing test (failed build per AGENTS.md) and would pin a contract that exists only on unmerged PR #942/#943 → left open for the operator, declined as an action.
2. **minor** — prior phase's `REVIEW_CODERABBIT_REPORT.md` contains zero marker lines, so there was no `findings` array to carry forward.

**Risk judgement**: MEDIUM (rationale 676 chars) — a docs-only diff reads green while the bead delivered nothing; the risk is signalling, not technical. `ask_advisor` failed (`invalid_grant` / "Refresh token expired"), so the level rests on my reasoning alone and the report says so.

**Verification**: base branch + branch check, `--name-only`/`--numstat`, identifier grep (exit 1), prior-phase marker greps (exit 1), doc-gate grep over CLAUDE.md/README.md/docs/user-guide.md/docs/cli-reference.md (exit 1 ⇒ no doc edits needed), python3 re-implementation of `ReviewFindings.extract_block/3` over 3 reports (mine: findings 1022 B, judgement 750 B, `json.loads`-clean; prior: absent; control foreman-jzycy: OK), fence-walk = exactly 4 exact unindented marker lines. No `mix test`: no `.ex/.exs` changed, and `packages/foreman_server/deps` + `_build` don't exist in this worktree; formatter has no `*.md` input.

kata `5q3f`: three phase-4 comments posted; issue left **open** with `needs-review` (bead still unimplemented by design).