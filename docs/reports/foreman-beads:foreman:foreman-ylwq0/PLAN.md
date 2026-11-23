# PLAN — origin fetch + origin-based run worktree (foreman-ylwq0)

## 1. Verdict

**Real bug.** No `git fetch` happens anywhere on the new-run worktree path.

- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447`
  `resolve_declared_base/2`: with no declared `worktree: base:` the base is
  `resolve_revision(project_root, "HEAD")` — the checkout's local HEAD, arbitrarily behind
  `origin/<branch>`.
- `grep -rn "fetch_branch" packages/foreman_server/lib` → only `exec/git.ex:568` (the helper) and
  `exec/worktree.ex:150` (`sync_branch/3`, used by `Workflow.AttachBranch` for FOLLOW-UP runs).
  New runs (`create_new_run_worktree/2`, run_executor.ex:4096) never fetch.
- `Exec.Git.fetch_branch/4` already fetches into `refs/remotes/<remote>/<branch>` only (refspec
  `exec/git.ex:573`), so it never touches the operator's working tree or branch pointer.
- **No `VcsBackend` module exists** (`grep -rl VcsBackend` → only a completed PRD) and there is no
  Jujutsu code. The seam is the `ForemanServer.VcsAdapter` behaviour + `VcsAdapter.Default`; route
  the fetch through it and do **not** invent a VcsBackend.

## 2. Root cause

`resolve_declared_base/2` (run_executor.ex:4447) answers "what commit is this run cut from?" with
the checkout's `HEAD`, never consulting the remote. Correct by design and untouched: a declared
`worktree: base:`, `apply_source_branch/4` (run_executor.ex:4470, deliberately a LOCAL branch),
ImplementationContext runs (frozen `source_revision`).

## 3. Failing check first

New file `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs`,
`defmodule ForemanServer.Workflow.RunExecutorOriginBaseTest`, `use ExUnit.Case, async: true`.
Real git only, no mocks; helpers `ForemanServer.TestSupport.PrFixSupport.git!/2` and
`commit_file!/3`. Copy the bare-origin + two-clone setup from
`test/foreman_server/exec/worktree_sync_remote_test.exs:20-40`: bare origin `root/origin.git`
(`-b main`); clone → `root/repo` (the registered checkout) and → `root/peer`; peer commits
`base.txt` and pushes `main`; repo pulls `main`.

Each case calls the new export `RunExecutor.__resolve_provisioned_base_for_test__(state, spec)` with
`state = %{task: %{project_id: "proj-1", task_id: "t-1", working_directory: repo}, run_id: "run-" <> String.duplicate("a", 32), worktree_spec: %{}, plan_context: nil}`.

1. `"the base is origin/<branch>, not the stale checkout HEAD"` — peer pushes a second commit
   (`remote_tip`); repo is NOT pulled; `spec = %{}`. Assert `{:ok, ^repo, ^remote_tip, nil, nil}`
   and `remote_tip != git!(repo, ["rev-parse", "HEAD"])`.
2. `"the operator checkout is untouched by the fetch"` — after case 1:
   `git!(repo, ["rev-parse", "HEAD"])` equals the SHA recorded before the call,
   `git!(repo, ["symbolic-ref", "--short", "HEAD"]) == "main"`,
   `git!(repo, ["status", "--porcelain"]) == ""`.
3. `"a checkout with no origin remote falls back to HEAD"` —
   `git!(repo, ["remote", "remove", "origin"])`; base equals the repo's local HEAD.
4. `"a branch the remote does not have falls back to HEAD"` —
   `git!(repo, ["checkout", "-q", "-b", "feat/never-pushed"])` + a local commit; base equals that
   local HEAD.
5. `"a declared base is resolved locally and never fetched"` — `spec = %{base: "main"}` on the
   no-origin repo of case 3; base equals the local `main` SHA.

Red before the fix: case 1 returns the stale local HEAD.

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/run_executor_origin_base_test.exs'
```

## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/exec/git.ex`

Add after `fetch_branch/4`'s `end` (line 594); `check_ref/2` (git.ex:398) already exists.

```elixir
  @doc "Whether `remote` is configured in `repo` (`git remote get-url`)."
  @spec remote_exists?(String.t(), String.t()) :: boolean()
  def remote_exists?(repo, remote) do
    with :ok <- check_ref(:remote, remote) do
      match?(
        {_output, 0},
        System.cmd("git", ["-C", repo, "remote", "get-url", remote], stderr_to_stdout: true)
      )
    else
      {:error, _} -> false
    end
  end
```

### Edit 2 — `packages/foreman_server/lib/foreman_server/vcs_adapter.ex`

(a) Add a callback after the `create_worktree` callback (before the `clean_worktree` `@doc`):

```elixir
  @doc """
  Fetch `branch` from `remote` and return the fetched remote tip, so a run's worktree is cut from
  the published branch, not the checkout's HEAD. Read-only w.r.t. the checkout: may only advance
  `refs/remotes/<remote>/<branch>`. `{:ok, :no_remote_tracking}` is the ABSENT case (no such
  remote, or the remote lacks the branch) and the caller falls back to HEAD; any other failure is
  an error, never an absent tip.
  """
  @callback fetch_base(repo_path :: String.t(), remote :: String.t(), branch :: String.t()) ::
              {:ok, String.t()} | {:ok, :no_remote_tracking} | {:error, term()}
```

(b) `@spec run/4` (lines 74-81): add `| :fetch_base` to the operation atom union.

(c) Add a `build_fun/2` clause after the `:create_worktree` clause:

```elixir
  defp build_fun(module, :fetch_base),
    do: fn args -> module.fetch_base(Enum.at(args, 0), Enum.at(args, 1), Enum.at(args, 2)) end
```

### Edit 3 — `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex`

(a) Add `| :fetch_base` to the operation union of this module's `@spec run/3` helper.

(b) Add `alias ForemanServer.Exec.Error, as: GitError` (line 17 already aliases `Exec.Git` as
`Git`), then the implementation after `create_worktree/3`'s `end`. No `vcs_operation.*` events: the
callback has no operation id and only advances a remote-tracking ref; transient failures are tagged
so `VcsAdapter.run/4` retries them. `fetch_branch/4`'s error `details` carry `:output` only on a
git failure (a rejected ref carries `:role`/`:ref`), so read it with `Map.get/3`.

```elixir
  @impl true
  def fetch_base(repo_path, remote, branch) do
    if Git.remote_exists?(repo_path, remote) do
      case Git.fetch_branch(repo_path, remote, branch) do
        :ok ->
          case Git.ref_sha(repo_path, "refs/remotes/#{remote}/#{branch}") do
            {:ok, sha} -> {:ok, sha}
            {:error, reason} -> {:error, {:remote_tip_unresolvable, remote, branch, reason}}
          end

        {:error, %GitError{details: details}} ->
          output = Map.get(details, :output, "")

          if output =~ "couldn't find remote ref" do
            {:ok, :no_remote_tracking}
          else
            {:error, {:transient, output}}
          end
      end
    else
      {:ok, :no_remote_tracking}
    end
  end
```

(`git fetch` of a branch the remote lacks exits 128 with
`fatal: couldn't find remote ref refs/heads/<branch>`; an unreachable remote exits 128 with a
different message, so it is retried and then surfaced.)

### Edit 4 — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`

(a) Add `alias ForemanServer.VcsAdapter` and
`alias ForemanServer.VcsAdapter.Default, as: DefaultAdapter` to the alias block (lines 73-96).

(b) In `resolve_run_base/2` (line 4424), non-ImplementationContext branch, change the `with` clause
`{:ok, base_ref} <- resolve_declared_base(spec, project_root) do` to
`{:ok, base_ref} <- resolve_declared_base(state, spec, project_root) do`.

(c) Replace `resolve_declared_base/2` (lines 4447-4458) with:

```elixir
  # With no declared `base:`, the run is cut from the PUBLISHED tip of the checkout's branch
  # (`origin/<branch>`), fetched first, not from the checkout's possibly-stale HEAD. The fetch only
  # advances `refs/remotes/origin/<branch>`: the working tree and branch pointer are never touched.
  # Falls back to HEAD only where nothing published exists to cut from (no `origin`, remote lacks
  # the branch, detached checkout); any other fetch failure is a typed error, never a silent cut
  # from a stale base. A `source_branch` task is cut from that LOCAL branch by
  # `apply_source_branch/4`, so it is not fetched.
  defp resolve_declared_base(state, spec, project_root) do
    case Map.get(spec, :base) do
      declared when is_binary(declared) and declared != "" ->
        case resolve_revision(project_root, declared) do
          {:ok, sha} -> {:ok, sha}
          {:error, reason} -> {:error, {:worktree_base_unresolvable, declared, reason}}
        end

      _ ->
        if source_branch(state) do
          resolve_revision(project_root, "HEAD")
        else
          resolve_origin_base(project_root)
        end
    end
  end

  defp resolve_origin_base(project_root) do
    case checkout_branch(project_root) do
      {:ok, branch} -> fetch_origin_base(project_root, branch)
      {:error, _detached_or_unresolvable} -> resolve_revision(project_root, "HEAD")
    end
  end

  defp fetch_origin_base(project_root, branch) do
    case VcsAdapter.run(DefaultAdapter, :fetch_base, [project_root, "origin", branch]) do
      {:ok, sha} when is_binary(sha) -> {:ok, sha}
      {:ok, :no_remote_tracking} -> resolve_revision(project_root, "HEAD")
      {:error, reason} -> {:error, {:origin_fetch_failed, "origin", branch, reason}}
    end
  end
```

`source_branch/1` (run_executor.ex:1557) and `checkout_branch/1` (run_executor.ex:1602, typed
`{:error, {:checkout_branch_unresolvable, repo_path, :detached_head}}`) already exist here; do not
redefine them. `resolve_run_base/2`'s two other callers discard `base_ref`
(`rehydrate_worktree_entry/2` run_executor.ex:1138 resume; follow-up path run_executor.ex:4040) —
they will now also fetch, which is correct (same checkout, refs-only). Do not add a suppress flag.

(d) Add the test export next to `__create_run_worktree_for_test__/2` (around line 5912):

```elixir
  @doc false
  def __resolve_provisioned_base_for_test__(state, spec), do: resolve_provisioned_base(state, spec)
```

### Edit 5 — behaviour stubs (a missing callback warning is a failed build)

Add to every `@behaviour ForemanServer.VcsAdapter` stub:

```elixir
    @impl true
    def fetch_base(_repo_path, _remote, _branch), do: raise("not used")
```

- `test/foreman_server/vcs_adapter_test.exs`: `StubOk` (line 6), `StubTransient` (26), `StubAuth`
  (52), `StubSucceedAfterTwo` (78).
- `test/foreman_server/vcs_adapter_default_test.exs`: `StubAlwaysTransient` (6).

### Edit 6 — documentation gate

- `docs/user-guide.md:120-121` ("…for every other workflow the base is the project checkout's
  `HEAD` when the run's first phase starts."): replace that `HEAD` claim — the base is the fetched
  `origin/<branch>` tip of the checkout's branch (Foreman runs `git fetch origin <branch>` first,
  which only advances `refs/remotes/origin/<branch>` and never touches your working tree or branch
  pointer); with no `origin` remote, no such branch on the remote, or a detached checkout the base
  is the checkout's `HEAD`; any other fetch failure fails the run with `origin_fetch_failed`.
- `docs/user-guide.md:566-567` ("**Base branch.**") and `docs/cli-reference.md:626` ("Foreman
  latches the run's PR base **branch**…"): keep the base BRANCH NAME rule as written (still the
  checkout's `HEAD` branch); add one sentence that the base COMMIT is that branch's fetched
  `origin` tip.
- `CLAUDE.md`, `README.md`: no edit — neither states where a run worktree is cut from
  (`CLAUDE.md:517` is a worktree-payload key list, `README.md:280` only names the `base:` field).

Identifiers added: error reason `origin_fetch_failed`; `VcsAdapter.fetch_base/3` and
`Exec.Git.remote_exists?/2` (internal Elixir API). None removed or renamed. No routes, config keys,
env vars, CLI verbs or MCP tools.

## 5. Verification

Narrow first, then full. Success = all green, zero warnings.

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/run_executor_origin_base_test.exs \
  test/foreman_server/workflow/run_executor_run_worktree_test.exs \
  test/foreman_server/workflow/run_executor_followup_worktree_test.exs \
  test/foreman_server/workflow/run_executor_resume_context_test.exs \
  test/foreman_server/workflow/run_executor_multi_repo_test.exs \
  test/foreman_server/vcs_adapter_test.exs test/foreman_server/vcs_adapter_default_test.exs \
  test/foreman_server/exec/worktree_sync_remote_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Environment: no `deps/` → `MIX_ENV=test mix deps.get` first; an ambient `DATABASE_URL` that fails
auth → override with `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_ylwq0`
and run `mix event_store.init` once.

## 6. Out of scope

- No `VcsBackend` module and no Jujutsu code; the adapter behaviour is the seam.
- Do not change `apply_source_branch/4`, the ImplementationContext branch of `resolve_run_base/2`,
  the declared-`base:` branch, `Workflow.AttachBranch`, `Exec.Worktree.sync_branch/3`,
  `repo_base/1` (secondary repos), `remember_run_base_branch/1`, or PR base BRANCH NAME resolution.
- No config key for the remote name (`"origin"` is the literal, as everywhere else), no new
  `vcs_operation.*` events, no retry/backoff knobs, no refactor of `resolve_revision/2`.
