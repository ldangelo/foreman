# PLAN — foreman-k9g4n: graceful degradation on fetch failure

## 1. Verdict

**Real bug, but its code path is NOT on this branch yet.** Read step 0 before anything else.

Evidence on this tree (HEAD `f0f3b083`, identical to `origin/main`):

- No run-start fetch exists. `resolve_declared_base/2`
  (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447`) resolves
  `HEAD` locally and never calls git fetch.
- `ForemanServer.Exec.Git.fetch_branch/4`
  (`packages/foreman_server/lib/foreman_server/exec/git.ex:568`) has exactly one caller,
  `Exec.Worktree.sync_branch/3` (`.../exec/worktree.ex:150`), the follow-up / PR-attach path.
  **A fetch failure must stay fatal there** (you cannot attach to a PR head you could not
  fetch). Do not touch it.
- The `git fetch origin <base_branch>` this bead is about is added by sibling bead
  `foreman-ylwq0` on open PR **#942** (branch
  `foreman/foreman-ylwq0/run-4c8b40838270b2b29b0aeb44d96e26bc`, merge-base = our HEAD).
  There it ends in `fetch_origin_base/3` returning the HARD error
  `{:error, {:origin_fetch_failed, remote, branch, reason}}` — precisely what this bead
  must turn into warn + continue on HEAD.

## 2. Root cause

`fetch_origin_base/3` in `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
(as added by PR #942) maps every non-absent fetch failure (offline, auth, unreachable
remote) to a typed error, which aborts worktree creation and therefore the run. Absent
cases (`{:ok, :no_remote_tracking}`) already fall back to local `HEAD`; transient/environmental
failures should degrade the same way, loudly, rather than block.

## 3. Step 0 — gate (do this first)

```
cd packages/foreman_server && grep -n "fetch_origin_base" lib/foreman_server/workflow/run_executor.ex
```

- **No match** (PR #942 not merged yet): there is nothing to degrade. Write exactly
  `Blocked: depends on PR #942 (foreman-ylwq0), which adds fetch_origin_base/3; no code change here.`
  as the sole content of `FIX_REPORT.md` and **stop**. Do NOT copy PR #942's code onto this
  branch: duplicating an unmerged sibling PR's diff makes both unmergeable and the merge gate
  is operator-only.
- **Match** (two lines, ~4476 and ~4485): continue with sections 4–6.

## 4. Failing check first

Append to `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs`
(file is created by PR #942; its `setup` already builds `ctx.repo` as a clone of a bare
`ctx.origin` whose `main` is ahead, and exposes `ctx.stale_head`):

```elixir
  test "a fetch that fails degrades to the checkout HEAD instead of failing the run", ctx do
    sh!(ctx.repo, ["remote", "set-url", "origin", Path.join(ctx.tmp, "gone.git")])

    assert {:ok, _repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(ctx.repo), %{})

    assert base_ref == ctx.stale_head
  end
```

Command that shows it red before the edits (it returns
`{:error, {:origin_fetch_failed, "origin", "main", _}}`):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_origin_base_test.exs'
```

## 5. Edits

All in `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` unless stated.

**Edit 1 — pass the run state into the fetch helper.** In `resolve_origin_base/2`, change the
call site:

```elixir
          {:ok, branch} -> fetch_origin_base(project_root, "origin", branch)
```

to

```elixir
          {:ok, branch} -> fetch_origin_base(state, project_root, "origin", branch)
```

**Edit 2 — degrade on failure.** Replace the whole of `fetch_origin_base/3`:

```elixir
  defp fetch_origin_base(project_root, remote, branch) do
    case VcsAdapter.run(DefaultAdapter, :fetch_base, [project_root, remote, branch], []) do
      {:ok, sha} when is_binary(sha) -> {:ok, sha}
      {:ok, :no_remote_tracking} -> resolve_revision(project_root, "HEAD")
      {:error, reason} -> {:error, {:origin_fetch_failed, remote, branch, reason}}
    end
  end
```

with:

```elixir
  # A fetch that FAILS (offline, auth, unreachable remote) must not block the run: the
  # run continues on the checkout's local `HEAD`, which may be stale. The degradation is
  # loud — a server-log warning AND an operator-visible run inbox note — never silent.
  defp fetch_origin_base(state, project_root, remote, branch) do
    case VcsAdapter.run(DefaultAdapter, :fetch_base, [project_root, remote, branch], []) do
      {:ok, sha} when is_binary(sha) ->
        {:ok, sha}

      {:ok, :no_remote_tracking} ->
        resolve_revision(project_root, "HEAD")

      {:error, reason} ->
        warn_origin_fetch_degraded(state, remote, branch, reason)
        resolve_revision(project_root, "HEAD")
    end
  end

  # Best-effort, like `dispatch_repo_base_branch/3`: the run already degraded, so a failed
  # inbox dispatch must not fail it on top. `dispatch_system_command/4` logs its own error.
  defp warn_origin_fetch_degraded(state, remote, branch, reason) do
    Logger.warning(
      "RunExecutor #{state.run_id} fetch of #{remote}/#{branch} failed (#{inspect(reason)}); " <>
        "continuing on the checkout HEAD, which may be a stale base",
      run_id: state.run_id,
      operation: "run_executor.origin_fetch_degraded",
      outcome: "degraded"
    )

    message_id = "origin-fetch-degraded:" <> state.run_id

    dispatch_system_command(
      "inbox.send",
      "workflow:executor:inbox.send:" <> message_id,
      "inbox:" <> state.run_id,
      %{
        run_id: state.run_id,
        message_id: message_id,
        body:
          "Could not fetch #{remote}/#{branch}; this run is based on the project checkout's " <>
            "local HEAD, which may be behind #{remote}/#{branch}.",
        metadata: %{severity: "warn"}
      }
    )

    :ok
  end
```

Notes for the implementer (do not re-derive these):

- `dispatch_system_command/4` is already defined at `run_executor.ex:3624`
  (`type, command_id, aggregate_id, payload`); `Logger` is already required in this module.
- `inbox.send` is handled by `ForemanServer.Aggregates.InboxThread`
  (`lib/foreman_server/aggregates/inbox_thread.ex:101`) on stream `"inbox:<run_id>"`; it needs
  `run_id`, `message_id`, `body` and dedupes by `message_id`, so a retried phase appends once.
  `CommandGateway.dispatch_system/2` accepts it (the `validate_aggregate_id/1` envelope check
  is on the operator path only). `severity: "warn"` is a whitelisted metadata value
  (`lib/foreman_server/mcp/tools.ex:2974`). Keep the body one sentence: bodies are capped at
  2 000 characters and must carry no command output, paths or secrets.

**Edit 3 — docs (the three places PR #942 wrote the old "fails the run" rule).** Replace the
"fails the run" clause with the degradation rule in each; keep the surrounding sentence:

1. `docs/user-guide.md` ~line 128: `... falls back to the local HEAD; a fetch that fails for
   any other reason fails the run rather than silently using a stale base.` →
   `... falls back to the local HEAD; a fetch that fails for any other reason (offline, auth,
   unreachable remote) logs a warning, posts a note on the run's inbox and continues on the
   checkout's local HEAD, which may be a stale base.`
2. `docs/cli-reference.md` ~line 623, sentence ending `... and a checkout with no origin
   remote falls back to the local HEAD.` → append: `A fetch that fails for any other reason
   also falls back to the local HEAD, with a warning on the run's inbox.`
3. `docs/lessons/phase-execution-and-pr-mechanics.md` ~line 220: `... falls back to the local
   HEAD; any other fetch failure fails the run instead of silently pinning a stale base.` →
   `... falls back to the local HEAD; any other fetch failure also falls back to the local
   HEAD, but loudly — Logger warning plus an inbox.send note on the run — so a stale base is
   never pinned silently.`

**Edit 4 — the test from section 4.**

## 6. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_origin_base_test.exs test/foreman_server/vcs_adapter_test.exs test/foreman_server/aggregates/inbox_thread_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = all three green, with the new test passing and every pre-existing test in
`run_executor_origin_base_test.exs` still passing. A single failure is a failed build.

Documentation gate: no new or renamed externally visible identifier (no new command type —
`inbox.send` already exists and is documented; no new event, route, flag, env var or config
key). The only documentation change is the three behaviour sentences in Edit 3; `README.md`
and `AGENTS.md` need none (grep for `origin_fetch_failed` and `fetch origin` returns no hits
in either).

## 7. Out of scope

- `Exec.Git.fetch_branch/4` and `Exec.Worktree.sync_branch/3`: the follow-up / PR-attach path
  must keep failing hard on a fetch failure.
- `VcsAdapter.fetch_base/3` and `VcsAdapter.Default.fetch_base/3`: their contract
  (`{:ok, sha} | {:ok, :no_remote_tracking} | {:error, _}`) stays exactly as PR #942 defines
  it; the degradation belongs to the caller.
- Sibling beads: `base_ref_policy` (foreman-zv8bi), base SHA on `RunBaseBranchRecorded`
  (foreman-i3qol), "behind origin" recommendation (foreman-qdt14), bare-remote test matrix
  (foreman-og6ro), user-guide rewrite (foreman-okend).
- Do not add a new event type for the warning; the per-run inbox is the existing
  operator-visible channel.
- Do not cherry-pick, merge or rebase PR #942 onto this branch, and do not merge any PR.
