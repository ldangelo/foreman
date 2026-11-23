Phase 1 done. Plan written, no code touched.

## Verdict: no code change — blocked

Plan: `docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md` (84 lines, well under the 200-line cap).

**Why blocked:** the bead presupposes code that isn't on this branch.

- `grep -rn "resolve_origin_base|fetch_origin_base|base_ref_policy"` over `packages/foreman_server/lib`, `packages/foreman_server/test`, `packages/foreman_cli` → **zero matches**.
- `run_executor.ex:4456` still `resolve_revision(project_root, "HEAD")` — worktree cut from local HEAD, no fetch exists to assert against.
- Test seam `__resolve_provisioned_base_for_test__/2` absent; `VcsAdapter.Default` has no `fetch_base/3` ⇒ a test file would not compile.

**Where it actually lives (all unmerged):**

| Assumption | Location | State |
| --- | --- | --- |
| `resolve_origin_base/2` :4472, `fetch_origin_base/3` :4485, `fetch_base/3` default.ex:142, seam :5964 | PR **#942** head `43be78e6` | OPEN |
| `base_ref_policy` setting (settings.ex:53) | PR **#943** | OPEN, **and unwired** — nothing under `lib/foreman_server/workflow/` reads it |

**Two kills on re-implementing:**

1. #942 already ships `test/foreman_server/workflow/run_executor_origin_base_test.exs` (+168, 6 tests) doing exactly the bare-origin-ahead scenario (seed/repo/peer clones, peer pushes `ahead.txt`, `assert base_ref == origin_tip` / `refute == stale_head`). Copying it = duplicate boundary coverage (AGENTS.md 5.7) + merge conflict.
2. "fetch failure degrades with a warning" **contradicts** #942's `{:error, {:origin_fetch_failed, ...}}` and AGENTS.md ("refuse what cannot be honoured"). That path is separate bead foreman-k9g4n / PR #944.

**Verification:** no test run — zero code delta, so nothing to validate. `git status --porcelain` → only the untracked report dir.

**Doc gate:** zero externally visible identifiers added/removed/renamed. Greps of `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` for the three identifiers → no hits. No edits needed to any of the four.

**kata:** `5q3f` created, claimed, commented w/ evidence, labelled `needs-review`, left **open** — operator call: close as dup of #942's test file, or re-scope to the `base_ref_policy: checkout` case after #943 is wired.

Notes: `ask_advisor` unusable (Anthropic oauth refresh 400 `invalid_grant`, refresh token expired); `foreman_inbox_send` / `foreman_task_add_comment` not exposed ⇒ no operator progress notes sent.