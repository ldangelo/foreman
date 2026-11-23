# Fix report — bead `foreman-i3qol`

## What changed

`RunBaseBranchRecorded` now carries the commit the base branch pointed at, and
the run view surfaces it.

- `packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`
  — the event gains the optional `base_sha` field; the moduledoc names the
  producers (`Workflow.RunExecutor`, `Workflow.RepoAttach`), the reader
  (`ProjectionStore`) and what the field is.
- `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
  — `run.record_base_branch` accepts an optional binary `base_sha` (a
  non-binary value is refused with `{:error, {:missing_or_invalid, :base_sha,
  value}}` — AGENTS.md §5.3) and emits a payload whitelisted to the event's
  declared fields, so replay stays decodable. The aggregate keeps no `base_sha`
  state: it is a read-model fact, not aggregate state.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  — the primary's base branch is resolved to the commit it points at
  (`git rev-parse --verify <ref>^{commit}`); an unresolvable revision records
  the branch alone. A secondary repository's base carries its own `base_sha`
  and `repo_id`.
- `packages/foreman_server/lib/foreman_server/workflow/repo_attach.ex`
  — a secondary repository's base branch is recorded with the SHA its
  `base_ref` names (`repo_base/1` resolves it from the repository's
  `default_branch` tip, else `HEAD`).
- `packages/foreman_server/lib/foreman_server/projection_store.ex`
  — `RunBaseBranchRecorded` stores `base_sha` on the primary run and per
  repository (`repo_base_shas`, keyed by `repo_id`); the `run_repositories` read
  model carries `base_sha` per repository.
- Tests — new
  `packages/foreman_server/test/foreman_server/aggregates/run_base_branch_test.exs`;
  `projection_store_run_repositories_test.exs` and
  `workflow/run_executor_pr_base_branch_test.exs` extended.
- Docs — `docs/lessons/architecture-and-events.md:222` (the event row) and
  `docs/user-guide.md:1362-1367` (`GET /api/runs/{id}`).

`README.md`, `docs/cli-reference.md` and `CLAUDE.md` need no edit: no route,
CLI verb, env var or config key changed, and the PR-finalize context still
reads only `base_branch`.

## Verification

```
MIX_ENV=test mix compile --warnings-as-errors          # exit 0
mix format --check-formatted <the 8 touched files>      # exit 0
DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_i3qol \
  TEST_DB_POOL_SIZE=5 MIX_ENV=test mix test \
  test/foreman_server/aggregates/run_base_branch_test.exs \
  test/foreman_server/projection_store_run_repositories_test.exs \
  test/foreman_server/workflow/run_executor_pr_base_branch_test.exs
# Result: 20 passed; ProjectionLeakGuard: no run left behind (exit 0)
```
