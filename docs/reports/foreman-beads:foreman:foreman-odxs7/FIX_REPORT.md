# Fix Report — beads:foreman:foreman-odxs7

## Verdict: cannot reproduce — no code change made

The reported defect does not exist on this branch. The plan's verdict ("cannot
reproduce — not on this tree") is correct; I independently re-verified every
claim before writing this report.

## Root cause

There is no defect in the code under review. The automated review read an
**abandoned branch**, not this one.

Plan evidence, each point re-verified against the working tree at HEAD
(`foreman/foreman-odxs7/run-e334fe4eda7d653789b3c8b5e5caa71f`, base `9606612c`):

- `packages/foreman_server/lib/foreman_server/overwatch.ex` is 209 lines and
  contains **none** of the named identifiers. Verification:
  `grep -n "ensure_single_writer\|live_workers_for\|wait_for_worker_to_exit\|inspect_run\|pids_live\|await_run_workers_exit\|def start_phase" lib/foreman_server/overwatch.ex`
  → one hit only, `113:  def start_phase(phase, opts) do`. So
  `ensure_single_writer/1`, `live_workers_for/1`, `wait_for_worker_to_exit/2`,
  `inspect_run/1` and `pids_live/1` do not exist here, and neither symptom (a)
  (`start_phase/2` returning `nil` when no worker is live) nor symptom (b)
  (`Process.alive?/1` on a keyword list / `Keyword.get/2` on a pid list) can
  occur.
- `start_phase/2` at `overwatch.ex:113` has no single-writer guard at all. Its
  `@spec` is `{:ok, map()} | {:error, term()}` and the only `with` arm is
  `with {:ok, env_map, resolved_secrets} <- build_launch_env(project_id, opts)`.
  There is no `with :ok <- ensure_single_writer(run_id)` to short-circuit to `nil`.
- The whole-repo grep
  `grep -rn "await_run_workers_exit\|worker_already_running\|single_writer" lib/ test/`
  in `packages/foreman_server` returns **no matches** — the rewrite the task
  asks for is not present on this branch either.
- `git diff origin/main HEAD -- packages/foreman_server/lib/foreman_server/overwatch.ex`
  is empty (exit 0), so nothing on this branch introduced or removed the guard.

Why the review saw it: per the plan, the broken version lives only in WIP
commit `b8cb4484` on branch `foreman/foreman-ws23g/run-2944c140…` (PR #922,
**CLOSED**, not an ancestor of HEAD or `main`) — the run the reviewer analysed.
The requested rewrite already exists, correctly implemented, in commit
`a01459d1` on branch `fix/worker-stop-single-writer`, i.e. **PR #923**.

## Change

**None.** No file in `packages/foreman_server` was modified. Per the phase
rules for a "cannot reproduce" verdict, no code was changed.

## Deviations from the plan

None. The plan's verdict is "cannot reproduce", which is branch rule 1, so step 3
(make the plan's edits) is void by construction. Verified rather than trusted:
identifier grep, `start_phase/2` body and spec, whole-repo grep, branch diff vs
`origin/main`, and the plan's test command.

## Tests

No tests added or changed — there is no behaviour on this branch to pin.

The plan's "failing check first" is a passing regression check, not a red one,
consistent with the verdict. Re-run:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/overwatch_test.exs \
  test/foreman_server/overwatch/worker_supervisor_test.exs --warnings-as-errors'
→ Result: 10 passed   (exit 0)
```

Reproduces the plan's number exactly. `ProjectionLeakGuard: judged 1 of 2
modules, no run left behind`. The interleaved `[error] GenServer ... ** (stop)
{:badmatch, :boom}` and `Retry attempt=1` lines are the crash-loop test
exercising its own fixture, not failures — the run is green.

Matching the plan's "Done looks like": two consecutive `start_phase/2` calls on
the same `run_id` both return `{:ok, …}` on this tree, which is exactly the
behaviour these tests cover. That is the *absence* of the guard, not the
presence of a working one.

## Local verification

| Command | Result |
| --- | --- |
| `wc -l lib/foreman_server/overwatch.ex` | 209 |
| `grep -n` the six named functions in `overwatch.ex` | only `def start_phase/2` at :113 |
| `grep -rn "await_run_workers_exit\|worker_already_running\|single_writer" lib/ test/` | no matches |
| `git diff origin/main HEAD -- .../overwatch.ex` | empty, exit 0 |
| `git branch --show-current` | `foreman/foreman-odxs7/run-e334fe4eda7d653789b3c8b5e5caa71f` |
| the two-file `mix test --warnings-as-errors` above | 10 passed, exit 0 |
| `gh pr view 923 --json number,state,mergeable,title,url` | `OPEN`, `MERGEABLE`, "fix(overwatch): stop a terminal run's live workers; refuse a second writer" |

## Follow-ups

1. **The real work is in PR #923, not here.** PR #923 (`a01459d1`,
   `fix/worker-stop-single-writer`) is OPEN / MERGEABLE / CLEAN and implements
   what this task describes: `ensure_single_writer/1` over
   `WorkerSupervisor.await_run_workers_exit(run_id, 2_000)` on the plain pid
   list, `Logger.error` plus `{:error, {:worker_already_running, run_id}}`, with
   tests in `test/foreman_server/overwatch/worker_stop_test.exs`. That PR
   should be reviewed and merged; re-implementing it on this branch would
   duplicate a boundary across branches (AGENTS.md §5.7) and conflict with it.
2. **Recommended disposition of the source bead:** close it as already
   addressed by #923 rather than re-deriving from this run. This branch
   intentionally carries no code, so merging it would be a no-op.
3. **Review-pipeline hygiene (root of this false positive):** the automated
   reviewer analysed run `run-2944c1407c448e4481b3017f8606ed76` whose branch was
   abandoned with PR #922 CLOSED, then filed the finding against a fresh branch
   cut from `main` that never contained that code. Findings should be
   discarded when the branch they were read from is not an ancestor of the
   review target's base. That is a reviewer-side fix, outside this task's scope.
4. `ask_advisor` was unavailable again this session (Advisor model
   `openai-codex/gpt-5.5` / OAuth `invalid_grant` → "model not found"), so the
   pre-completion review could not be run. Independent re-verification above
   substitutes for it.

## Documentation gate

Zero externally visible identifiers added, removed or renamed — no code
changed. `worker_already_running`, `await_run_workers_exit` and
`stop_run_workers` grep clean across `CLAUDE.md`, `README.md`,
`docs/user-guide.md` and `docs/cli-reference.md` on this branch.

- `CLAUDE.md` — no edit needed (no operator-visible change).
- `README.md` — no edit needed.
- `docs/user-guide.md` — no edit needed.
- `docs/cli-reference.md` — no edit needed.

Those identifiers arrive with PR #923, which carries its own doc edits.
