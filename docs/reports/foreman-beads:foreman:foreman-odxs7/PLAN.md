# PLAN — Repair the single-writer guard (beads:foreman:foreman-odxs7)

## 1. Verdict

**Cannot reproduce. No code change.** Stop after reading this file.

The reported defect is in code that does not exist on this branch. Every function the
task names is absent from
`packages/foreman_server/lib/foreman_server/overwatch.ex` (209 lines on this tree):

```
$ grep -n "ensure_single_writer\|live_workers_for\|wait_for_worker_to_exit\|inspect_run\|pids_live\|require Logger\|@single_writer" \
    packages/foreman_server/lib/foreman_server/overwatch.ex
(no matches)
```

`start_phase/2` (overwatch.ex:113) has no guard clause at all:

```elixir
project_id = Keyword.get(opts, :project_id) || project_id_from_phase(phase)

with {:ok, env_map, resolved_secrets} <- build_launch_env(project_id, opts) do
```

so symptom (a) — "`start_phase/2` returns `nil` instead of `{:ok, map}`, no worker can be
launched at all" — cannot happen here, and neither can symptom (b).

The file is byte-identical to `origin/main`:

```
$ git diff --stat origin/main HEAD -- packages/foreman_server/lib/foreman_server/overwatch.ex
(empty)
```

Proof the launch path is healthy on this tree (run in this worktree):

```
$ devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
    test/foreman_server/overwatch_test.exs \
    test/foreman_server/overwatch/worker_supervisor_test.exs --warnings-as-errors'
Result: 10 passed
```

`test/foreman_server/overwatch_test.exs` calls `Overwatch.start_phase/2` seven times,
including two launches for the *same* `run_id` back to back (overwatch_test.exs:306 and
:328), and both return `{:ok, launch}`.

### Where the broken code actually lives

- The broken version (`live_workers_for/1` returning `[run_id: …, pids: …]`,
  `wait_for_worker_to_exit/2` calling `Process.alive?/1` on that keyword list,
  `Keyword.get(live, :run_id)` on a pid list, `inspect_run/1`, `pids_live/1`) exists
  only in WIP commit `b8cb4484` on branch
  `foreman/foreman-ws23g/run-2944c1407c448e4481b3017f8606ed76`. Its PR **#922 is CLOSED**
  and `b8cb4484` is **not** an ancestor of `HEAD` or of `origin/main`
  (`git merge-base --is-ancestor b8cb4484 HEAD` → false). The automated review that
  produced this task read that abandoned branch, not `main`.
- The requested rewrite **already exists and is correct** in commit `a01459d1` on branch
  `fix/worker-stop-single-writer` = **PR #923, OPEN, MERGEABLE, base `main`**. It is
  exactly the shape this task asks for:

  ```elixir
  # packages/foreman_server/lib/foreman_server/overwatch.ex (PR #923)
  defp ensure_single_writer(run_id) do
    case WorkerSupervisor.await_run_workers_exit(run_id, @single_writer_wait_ms) do
      :ok ->
        :ok

      {:error, :timeout} ->
        Logger.error(
          "Overwatch: refusing to start a worker for run #{run_id}: a worker of that run is still alive",
          run_id: run_id,
          operation: "overwatch.start_phase"
        )

        {:error, {:worker_already_running, run_id}}
    end
  end
  ```

  with `WorkerSupervisor.await_run_workers_exit/2` polling the **plain pid list** from
  `list_pids_for_run/1` filtered by `Process.alive?/1` (`@worker_poll_ms 50`,
  `@single_writer_wait_ms 2_000`), and `start_phase/2` reading
  `with :ok <- ensure_single_writer(run_id), {:ok, env_map, …} <- build_launch_env(…)`.
  Its tests live in `packages/foreman_server/test/foreman_server/overwatch/worker_stop_test.exs`
  under `describe "Overwatch.start_phase/2 keeps one writer per run"`:
  - "refuses a second worker while one of the run is alive, and starts nothing" —
    asserts `{:error, {:worker_already_running, ^run_id}}`;
  - "starts a worker for another run beside it";
  - "waits for a worker that is on its way out instead of refusing the launch";
  plus `describe "WorkerSupervisor.await_run_workers_exit/2"` with three cases.

## 2. Root cause

None in this repository's `main` line. The bug report is a stale read of an abandoned
WIP commit (`b8cb4484`, PR #922 closed). The "done looks like" condition's first half —
`Overwatch.start_phase/2` returns `{:ok, …}` for a run with no live worker — already
holds on this tree and is covered by the 10 passing tests above. The second half — the
`{:error, {:worker_already_running, run_id}}` refusal — is not *broken* here, it is
simply not present yet on `main`, and the change that adds it is PR #923, already open,
mergeable and tested.

Implementing it a second time on this branch would create a conflicting duplicate of
PR #923's `ensure_single_writer/1` and `await_run_workers_exit/2`, which violates the
surgical-change rule (AGENTS.md §4) and §5.7 (never duplicate a boundary).

## 3. Failing check first

There is no failing check to write: the behaviour the task calls broken cannot be made
to fail on this tree. The command that demonstrates the launch path is green is the one
in §1:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/overwatch_test.exs \
  test/foreman_server/overwatch/worker_supervisor_test.exs --warnings-as-errors'
```

Expected: `Result: 10 passed`.

## 4. Edits

**None.** Do not modify any `.ex` or `.exs` file.

The only file this run writes is this plan artifact plus the fix workflow's own report
artifact. Leave the branch otherwise clean.

If a later operator decides `main` must carry the guard before PR #923 lands, the
correct action is to merge or rebase PR #923 (`fix/worker-stop-single-writer`,
`a01459d1`) — an operator-only merge gate — **not** to re-author the guard here.

## 5. Verification

Run the narrowest suite, confirming nothing regressed:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/overwatch_test.exs \
  test/foreman_server/overwatch/worker_supervisor_test.exs --warnings-as-errors'
```

Success = `Result: 10 passed`, exit code 0, no warnings. (Already verified above; the
implementer re-running it is the whole verification step, since the diff is empty.)

No formatter or Credo run is needed for an empty code diff; run
`devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'`
only if the report artifact edits touched Elixir files (they must not).

## 6. Out of scope

- Do **not** add `ensure_single_writer/1`, `live_workers_for/1`,
  `wait_for_worker_to_exit/2`, `inspect_run/1`, `pids_live/1`,
  `@single_writer_wait_ms`, `@single_writer_poll_ms`, or `require Logger` to
  `packages/foreman_server/lib/foreman_server/overwatch.ex`.
- Do **not** add `await_run_workers_exit/2`, `stop_run_workers/1`, `live_pids_for_run/1`
  or `ForemanServer.Overwatch.StopReport` to
  `packages/foreman_server/lib/foreman_server/overwatch/worker_supervisor.ex` — they are
  PR #923's surface.
- Do **not** touch `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`,
  `.../overwatch/adapters/jido_harness_worker.ex`,
  `.../agent_runtime/jido_harness/driver.ex`, `.../overwatch/launch_worker.ex`,
  `.../review/analyzer.ex`, or `.../exec/runners/overwatch.ex` — all of those belong to
  the sibling gaps of the same stale review, and to PR #923.
- Do **not** create `test/foreman_server/overwatch/worker_stop_test.exs`; it exists on
  `fix/worker-stop-single-writer`.
- Do **not** cherry-pick, merge, rebase onto, or otherwise import `a01459d1` /
  `b8cb4484`. Do not merge PR #923 — the merge gate is operator-only (AGENTS.md).
- Documentation gate: this plan adds, removes and renames **zero** externally visible
  identifiers (no command/event types, MCP tools, HTTP routes, CLI verbs/flags, env
  vars, config keys, workflow or prompt names). Greps of `CLAUDE.md`, `README.md`,
  `docs/user-guide.md`, `docs/cli-reference.md` for `worker_already_running`,
  `await_run_workers_exit` and `stop_run_workers` return nothing on this branch — those
  names arrive with PR #923, which carries its own `CLAUDE.md` and `docs/user-guide.md`
  edits. **No documentation file needs editing for this run**, because the run changes
  no code and nothing operator-visible.
