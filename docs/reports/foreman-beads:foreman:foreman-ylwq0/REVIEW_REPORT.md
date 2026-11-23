Phase done.

## What happened

Committed range (`main...HEAD`) had **only report files** — the `fix` phase committed a plan-recovery note, no code. Bead unimplemented, and this is the workflow's last phase ⇒ implemented it here, then reviewed the result against `AGENTS.md` + `docs/lessons/`.

## Changes (uncommitted)

- `exec/git.ex` — `remote_exists?/2`
- `vcs_adapter.ex` — `fetch_base/3` callback + `:fetch_base` op + dispatch clause
- `vcs_adapter/default.ex` — `fetch_base/3` impl (`{:ok, sha}` / `{:ok, :no_remote_tracking}` / `{:error, …}`); moduledoc exception for event-less op
- `workflow/run_executor.ex` — `resolve_declared_base/3` → `resolve_origin_base/2` → `fetch_origin_base/3`: base = fetched `origin/<branch>` tip; absent cases (no remote / branch missing / detached / task `source_branch`) → local HEAD; other fetch failures → typed `{:error, {:origin_fetch_failed, …}}` (run fails, no silent stale base)
- New test `run_executor_origin_base_test.exs` (6 tests) + 5 adapter behaviour stubs
- Docs: `docs/user-guide.md`, `docs/cli-reference.md`, `docs/lessons/phase-execution-and-pr-mechanics.md` — origin-tip base, ref-only side effect, declared-`base` exception, HEAD fallback

## Findings

9 (`repo-rules`): 8 fixed, 1 declined (F9 — secondary repos still base on `default_branch` tip/local HEAD; out of scope). Previous phase's report had **no** findings block ⇒ nothing carried forward.

## Verification

`mix format --check-formatted` 0 · `mix compile --warnings-as-errors` 0 · suites: origin-base 6, adapters 36, run-worktree 55, follow-up 4, resume 7, multi-repo 36, source-branch 9, PR-base 7, base-branch-env 4, run_executor 51, git 17, worktree 10, worktree_sync_remote 14 — all 0. Final combined re-run 53 passed.

Report: `docs/reports/foreman-beads:foreman:foreman-ylwq0/REVIEW_REPORT.md` — parser-verified: `ReviewFindings.read/1` → 9 findings (8 fixed, 1 declined), `PrRisk.parse_judgement/1` → recorded/MEDIUM.