Phase 2 is complete. Final state:

**Outcome: Blocked — no code changes, no tests added, nothing committed.**

`FIX_REPORT.md` (7477 B) at `docs/reports/foreman-beads:foreman:foreman-og6ro/FIX_REPORT.md` is the only deliverable; Foreman owns the commit/PR.

Why blocked (all re-verified in this phase, paths under `packages/foreman_server/`):
- `grep -rn "resolve_origin_base\|fetch_origin_base\|base_ref_policy\|__resolve_provisioned_base_for_test__" lib test` → **zero matches**. The identifiers the bead names don't exist on this branch.
- `lib/foreman_server/workflow/run_executor.ex:4447-4458` `resolve_declared_base/2` still ends at `:4456` with `resolve_revision(project_root, "HEAD")` — the worktree is cut from the local checkout, no fetch, no `origin/<branch>` read. Nothing to assert against.
- The behaviour lives only on **unmerged PR #942**, which *already ships* `test/foreman_server/workflow/run_executor_origin_base_test.exs` (6 tests, same scenario: bare origin advanced by a peer, `assert base_ref == origin_tip` / `refute == stale_head`). Copying it would duplicate boundary coverage (AGENTS.md §5.7) and guarantee a merge conflict.
- The "fetch failure degrades with a warning" assertion contradicts #942's typed `{:error, {:origin_fetch_failed, remote, branch, reason}}` and the "refuse what cannot be honoured" invariant; that path is separate bead `foreman-k9g4n` / PR #944.
- `base_ref_policy` exists only on unmerged PR #943 and nothing under `lib/foreman_server/workflow/` reads it, so there is no `checkout` policy behaviour to preserve.

Note worth your attention: the real plan (8136 B / 84 lines) exists only in git at `912dd597`; the working tree now holds a 31-line summary. I did **not** restore it — the committed copy is authoritative but editing `PLAN.md` is outside this phase's contract, so the restoration is your call. Run `git checkout 912dd597 -- '<PLAN.md path>'` to recover it.

Tooling gaps during this phase: `foreman_inbox_send`, `foreman_task_add_comment` and `ask` all unavailable, so no operator progress notes were sent. `ask_advisor` still fails with Anthropic oauth `400 invalid_grant` ("Refresh token expired") — needs re-auth. Context compaction is refused for this session (request exceeds the 43,008-token accept limit), so it couldn't be folded.

`kata 5q3f` left OPEN, labelled `needs-review`, for your close-as-dup-after-#942 vs re-scope call.