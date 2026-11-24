# PLAN — foreman-1lo2p (part 1): reuse an existing run worktree instead of failing

Worktree rebased onto `origin/main` tip `ab53fed7`. All paths below are relative to
`packages/foreman_server/` unless they start with `docs/`.

## 1. Verdict

**Real bug, reproducible on the current tree.**

`lib/foreman_server/vcs_adapter/default.ex:87-128` (`create_worktree/3`) unconditionally runs
`git worktree add` and maps any non-zero exit to `{:error, {:git_worktree_create_failed, code, output}}`.
There is no probe for an already-registered worktree.

Verified with real git (scratch repo, not in the worktree):

```
git worktree add -b feat/a .worktrees/wt1 HEAD   -> 0
git worktree add    .worktrees/wt1 feat/a        -> 128  "fatal: '.worktrees/wt1' already exists"
```

`lib/foreman_server/workflow/worktree.ex:99-115` skips git only when the caller passes
`reuse_existing: true`, and only the follow-up/AttachBranch path does
(`lib/foreman_server/workflow/run_executor.ex:4079`). `ensure_run_worktree/2`
(`run_executor.ex:3962-3973`) falls through to `create_run_worktree/2` whenever
`state.run_worktree` is nil, so a relaunch without `resume_from` hits the 128 and fails the run
while the worktree still holds uncommitted work.

Other verified git facts the fix depends on:

- An **empty** pre-existing directory at the target path is accepted by `git worktree add` (exit 0).
  Current behaviour; the fix must not turn that into an error.
- A **non-empty, non-worktree** directory gives 128 `fatal: '<path>' already exists`.
- `git worktree list --porcelain` emits `worktree <abs-path>` / `branch refs/heads/<branch>` (or
  `detached`) per block; on macOS the recorded path is symlink-resolved (`/private/var/...`).

## 2. Root cause

`ForemanServer.VcsAdapter.Default.create_worktree/3` has no "already provisioned" branch: it treats
`git worktree add` as the only way to arrive at a usable worktree.

## 3. Failing check first

File: `test/foreman_server/vcs_adapter_default_test.exs`, inside the existing
`describe "create_worktree/3"` block (ends at line ~272). Its `setup` already builds a scratch repo
under `System.tmp_dir!()` and removes it in `on_exit`. Reuse the existing `run_git!/1` helper
(line 533) and the existing init/commit preamble copied from
`test "creates a worktree on a named branch and captures git output"`.

Add three tests:

1. `"reuses an existing worktree on the same branch and leaves uncommitted work intact"`
   - init repo + commit, `base_sha = rev-parse HEAD`.
   - First `Default.create_worktree(repo, worktree_path, opts)` with `branch: "feat/reuse"` → `{:ok, _}`.
   - `File.write!(Path.join(worktree_path, "dirty.txt"), "WIP")`.
   - Call `Default.create_worktree(repo, worktree_path, opts)` again (fresh `operation_id`).
   - Assert `{:ok, result}`; `result.reused == true`; `result.path == worktree_path`;
     `result.branch == "feat/reuse"`; `result.output == ""`.
   - Assert `File.read!(Path.join(worktree_path, "dirty.txt")) == "WIP"`.

2. `"refuses a path held by a worktree on a different branch"`
   - Create the worktree at `worktree_path` on `"feat/held"`.
   - Call `Default.create_worktree(repo, worktree_path, opts_with_branch("feat/other"))`.
   - Assert `{:error, {:worktree_path_unusable, ^worktree_path, {:branch_mismatch, "feat/held"}}}`.

3. `"refuses a plain non-worktree directory at the path"`
   - `File.mkdir_p!(worktree_path)` and `File.write!(Path.join(worktree_path, "junk.txt"), "x")`.
   - Assert `{:error, {:worktree_path_unusable, ^worktree_path, :not_a_worktree}}`.

Command that shows them failing on unmodified code (from `packages/foreman_server`):

```
mix test test/foreman_server/vcs_adapter_default_test.exs --warnings-as-errors
```

Expected before the fix: test 1 and test 2 fail with
`{:error, {:git_worktree_create_failed, 128, "fatal: '...' already exists"}}`; test 3 fails the same way.

## 4. Edits

All in `lib/foreman_server/vcs_adapter/default.ex`. No change to
`lib/foreman_server/workflow/worktree.ex` is needed: `run_create_git/8` passes the adapter's
`{:ok, result}` straight through and `Worktree.create/1` ignores extra result keys.

**Edit 1 — probe before `git worktree add`.** In `create_worktree/3`, replace lines 99-100:

```elixir
    args = Git.worktree_add_args(repo_path, worktree_path, branch, base)

    case System.cmd("git", args, stderr_to_stdout: true) do
```

with a `case` on the new probe, keeping the existing `System.cmd` branch as the `:create` arm:

```elixir
    case existing_worktree_disposition(repo_path, worktree_path, branch) do
      :reuse ->
        result = %{path: worktree_path, base: base, branch: branch, output: "", reused: true}
        emit_completed(operation_id, "worktree_create", target, result, metadata)
        {:ok, result}

      {:unusable, reason} ->
        reason = {:worktree_path_unusable, worktree_path, reason}
        emit_failed(operation_id, "worktree_create", target, reason, 0, metadata)
        {:error, reason}

      :create ->
        args = Git.worktree_add_args(repo_path, worktree_path, branch, base)

        case System.cmd("git", args, stderr_to_stdout: true) do
          ... existing body unchanged ...
        end
    end
```

In the existing success arm, add `reused: false` to the result map so both arms carry the key:

```elixir
            result = %{path: worktree_path, base: base, branch: branch, output: output, reused: false}
```

(`exclude_dotbeads/1` stays only inside the `:create` arm — a reused worktree is never touched.)

**Edit 2 — the probe itself.** Add a private function directly after `create_worktree/3`
(before the `exclude_dotbeads/1` comment block at line ~130):

```elixir
  # Decide what an existing path at `worktree_path` means. A relaunched
  # executor arrives here with the run's worktree already on disk holding
  # uncommitted work: re-running `git worktree add` exits 128 and fails the
  # run. Reuse is only safe when git itself records the path as a linked
  # worktree checked out on exactly `branch`; anything else is an unusable
  # path, never a silent reset. An absent or EMPTY directory is not an
  # obstruction (`git worktree add` accepts an empty dir), so it falls
  # through to the normal create path.
  defp existing_worktree_disposition(repo_path, worktree_path, branch) do
    cond do
      not File.dir?(worktree_path) -> :create
      empty_dir?(worktree_path) -> :create
      true -> classify_registered(repo_path, worktree_path, branch)
    end
  end

  defp empty_dir?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp classify_registered(repo_path, worktree_path, branch) do
    case Git.worktree_list(repo_path) do
      {:ok, worktrees} ->
        target = canonicalize(worktree_path)

        case Enum.find(worktrees, &(canonicalize(&1.path) == target)) do
          nil -> {:unusable, :not_a_worktree}
          %{branch: ^branch} when is_binary(branch) -> :reuse
          %{branch: nil} -> {:unusable, :detached}
          %{branch: other} -> {:unusable, {:branch_mismatch, other}}
        end

      # Cannot prove reuse is safe: let `git worktree add` run and report
      # its own error rather than inventing one.
      {:error, _reason} ->
        :create
    end
  end
```

`canonicalize/1` (line 260) and `Git.worktree_list/1`
(`lib/foreman_server/exec/git.ex:96`, returns `[%{path: ..., branch: ...}]` with `branch` already
stripped of `refs/heads/`) both already exist — do not add new helpers for either.

**Edit 3 — CHANGELOG.** `packages/foreman_server/CHANGELOG.md`, as the first bullet under
`## Unreleased` → `### Fixed`:

```markdown
- **Relaunching a run's executor no longer fails the run when its worktree already exists.**
  `VcsAdapter.Default.create_worktree/3` now probes `git worktree list --porcelain` first: a path
  already registered as a linked worktree on the same branch is reused untouched
  (`reused: true`, uncommitted work preserved) instead of exiting
  `{:git_worktree_create_failed, 128, ...}`. A path held by a worktree on another branch, a
  detached worktree, or a plain non-empty directory is refused with
  `{:worktree_path_unusable, path, reason}`.
```

**Edit 4 — user guide.** `docs/user-guide.md`, section `### Restart recovery and external effects`
(heading at line 1277). Append one sentence to the end of the paragraph that starts
"If the resume had to re-provision the run's worktree" (line ~1281):

```
A relaunch that finds the run's worktree already on disk and checked out on the run's branch now reuses it untouched instead of failing the run, so uncommitted work there survives; a path held by a worktree on another branch, a detached worktree, or an unrelated directory is refused with `{:worktree_path_unusable, path, reason}`.
```

## 5. Verification

From `packages/foreman_server`:

```
mix test test/foreman_server/vcs_adapter_default_test.exs --warnings-as-errors
mix test test/foreman_server/workflow/run_executor_run_worktree_test.exs --warnings-as-errors
mix format --check-formatted lib/foreman_server/vcs_adapter/default.ex test/foreman_server/vcs_adapter_default_test.exs
```

Success = both test files green (0 failures, no warnings) and `mix format --check-formatted` exit 0.
`run_executor_run_worktree_test.exs` is the regression guard: it drives `create_worktree/3` against
real git, including the resume-rehydrate reuse path.

Documentation gate: the only new externally visible identifier is the error tuple
`{:worktree_path_unusable, path, reason}`. `grep` of `CLAUDE.md`, `README.md`,
`docs/user-guide.md`, `docs/cli-reference.md` for `worktree_path_unusable` and
`git_worktree_create_failed` returned no hits before this change, so the only doc edits are the two
above (CHANGELOG + the user-guide sentence). No route, CLI verb, env var, config key or MCP tool
changes.

PR title: `fix(vcs): reuse an existing run worktree instead of failing with git 128`.

## 6. Out of scope

- Part (2) of the bead (resuming a failed run in place) — tracked separately.
- `run reset`, `run resume`, `lib/foreman_server/workflow/run_executor.ex`,
  `lib/foreman_server/exec/git.ex`, and the Go CLI.
- `lib/foreman_server/workflow/worktree.ex` — no edit required; leave `reuse_existing:` as is.
- Never reset, checkout, clean or prune a reused worktree, and never relax the branch check.
- Stale registrations (path registered but directory gone): the probe sees no directory and falls
  through to git, which keeps today's error. Do not add pruning.
- Do not commit anything under `.beads/` or `docs/reports/`, and do not add this plan to the PR.
- Do not run the full suite; the two test files above plus format are the whole check.
