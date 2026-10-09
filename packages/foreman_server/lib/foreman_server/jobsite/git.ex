defmodule ForemanServer.Jobsite.Git do
  @moduledoc """
  Git primitives for Jobsite. Every function returns `:ok | {:ok, term} | {:error, %Error{}}`,
  shelling out via `System.cmd/3` and treating exit status as the only success
  signal — matching `RunExecutor.git_ok/2`'s documented reasoning: matching on
  empty output as well mis-reads a successful command that emitted a warning
  (CRLF conversion, embedded repository) as a failure.
  """

  alias ForemanServer.Jobsite.Error

  @type commit :: %{sha: String.t(), subject: String.t()}

  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def current_branch(repo) do
    # `symbolic-ref --quiet --short HEAD`, not `rev-parse --abbrev-ref HEAD`,
    # which prints the literal string "HEAD" on a detached checkout.
    run(["-C", repo, "symbolic-ref", "--quiet", "--short", "HEAD"])
    |> map_ok(&String.trim/1)
    |> tag_error(:git_failed)
  end

  @spec head_sha(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def head_sha(repo) do
    run(["-C", repo, "rev-parse", "HEAD"])
    |> map_ok(&String.trim/1)
    |> tag_error(:git_failed)
  end

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  def branch_exists?(repo, branch) do
    case System.cmd(
           "git",
           ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  @spec worktree_add(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def worktree_add(repo, path, branch, base) do
    args =
      if branch_exists?(repo, branch) do
        ["-C", repo, "worktree", "add", path, branch]
      else
        ["-C", repo, "worktree", "add", "-b", branch, path, base]
      end

    run(args) |> as_ok() |> tag_error(:worktree_create_failed)
  end

  @spec worktree_remove(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def worktree_remove(repo, path) do
    with {:ok, _} <- run(["-C", repo, "worktree", "remove", path]),
         {:ok, _} <- run(["-C", repo, "worktree", "prune"]) do
      :ok
    else
      {:error, reason} ->
        {:error, Error.new(:git_failed, "git worktree remove/prune failed", %{reason: reason})}
    end
  end

  @spec worktree_list(String.t()) ::
          {:ok, [%{path: String.t(), branch: String.t() | nil}]} | {:error, Error.t()}
  def worktree_list(repo) do
    case run(["-C", repo, "worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        {:ok, parse_worktree_list(output)}

      {:error, reason} ->
        {:error, Error.new(:git_failed, "git worktree list failed", %{reason: reason})}
    end
  end

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n", trim: true)

      path =
        Enum.find_value(lines, fn line ->
          case line do
            "worktree " <> p -> p
            _ -> nil
          end
        end)

      branch =
        Enum.find_value(lines, fn line ->
          case line do
            "branch refs/heads/" <> b -> b
            _ -> nil
          end
        end)

      %{path: path, branch: branch}
    end)
    |> Enum.filter(&(&1.path != nil))
  end

  @spec sparse_exclude(String.t(), [String.t()]) :: :ok | {:error, Error.t()}
  def sparse_exclude(_path, []), do: :ok

  def sparse_exclude(path, patterns) do
    with {:ok, _} <- run(["-C", path, "sparse-checkout", "init", "--no-cone"]) do
      set_args =
        Enum.flat_map(patterns, fn p -> ["!#{p}", "!#{p}/**"] end)

      run(["-C", path, "sparse-checkout", "set", "/*" | set_args])
      |> as_ok()
      |> tag_error(:git_failed)
    else
      {:error, reason} ->
        {:error, Error.new(:git_failed, "git sparse-checkout init failed", %{reason: reason})}
    end
  end

  # A `git status` that cannot run (corrupt index, lock, permissions) is NOT evidence of
  # a clean tree. The caller uses this to decide whether a worktree may be deleted, so
  # the unknown case answers true: keep the directory rather than destroy unsaved work.
  @spec dirty?(String.t()) :: boolean()
  def dirty?(path) do
    File.dir?(path) and status_porcelain_dirty?(path)
  end

  defp status_porcelain_dirty?(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain", "--untracked-files=all"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) != ""
      {_output, _code} -> true
    end
  end

  # Emptiness is decided by `git status --porcelain`, never by `git commit`'s
  # exit code: after `git add -A` a clean tree and a genuine failure both
  # exit 1, and git prints "nothing to commit" to stdout instead of staying
  # silent, so "exit 1 with empty output means clean" matches the failure
  # case and reports real errors as a clean tree. `--untracked-files=all` so
  # a change whose only output is a new, never-added file counts as dirty. A
  # clean tree is `{:ok, :nothing_to_commit}` and creates no commit.
  #
  # Every failure is `{:error, %Error{code: :commit_failed}}` whose details
  # name the git step that failed (`:stage` is `:status`, `:add` or
  # `:commit`) and carry git's own exit code and output as `:reason`
  # (`{:git_status_failed | :git_add_failed | :git_commit_failed, code,
  # output}`) — a caller that must tell "could not read the tree" from "could
  # not commit it" (`RunExecutor`'s phase-commit failure reasons) can, and
  # nothing is reported as a skip.
  #
  # Identity is passed as `-c` overrides rather than read from config, so the
  # commit cannot fail on a checkout with no `user.email`/`user.name` set;
  # `--no-verify` so a repository pre-commit hook cannot fail the commit or
  # rewrite the agent's output.
  @spec commit_all(String.t(), String.t(), keyword()) ::
          {:ok, :nothing_to_commit} | {:ok, :committed} | {:error, Error.t()}
  def commit_all(path, message, opts \\ []) do
    name = Keyword.get(opts, :name, "Foreman")
    email = Keyword.get(opts, :email, "foreman@localhost")

    with {:ok, dirty?} <- status_dirty(path),
         true <- dirty? || {:clean, :nothing_to_commit},
         :ok <- git_step(["-C", path, "add", "-A"], :add, :git_add_failed),
         :ok <-
           git_step(
             [
               "-C",
               path,
               "-c",
               "user.name=#{name}",
               "-c",
               "user.email=#{email}",
               "commit",
               "--no-verify",
               "-m",
               message
             ],
             :commit,
             :git_commit_failed
           ) do
      {:ok, :committed}
    else
      {:clean, :nothing_to_commit} -> {:ok, :nothing_to_commit}
      {:error, %Error{}} = error -> error
    end
  end

  defp status_dirty(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain", "--untracked-files=all"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, String.trim(output) != ""}

      {output, code} ->
        {:error, commit_error(:status, {:git_status_failed, code, String.trim(output)})}
    end
  end

  defp git_step(args, stage, tag) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, commit_error(stage, {tag, code, String.trim(output)})}
    end
  end

  defp commit_error(stage, reason),
    do: Error.new(:commit_failed, "git #{stage} failed", %{stage: stage, reason: reason})

  @spec commits_between(String.t(), String.t(), String.t()) ::
          {:ok, [commit()]} | {:error, Error.t()}
  def commits_between(path, base_sha, head_ref) do
    case run(["-C", path, "log", "--format=%H%x00%s", "#{base_sha}..#{head_ref}"]) do
      {:ok, output} ->
        commits =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\0", parts: 2) do
              [sha, subject] -> %{sha: sha, subject: subject}
              [sha] -> %{sha: sha, subject: ""}
            end
          end)

        {:ok, commits}

      {:error, reason} ->
        {:error, Error.new(:git_failed, "git log failed", %{reason: reason})}
    end
  end

  @spec merge(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:merge_conflict, String.t()}}
  def merge(repo, branch) do
    case run(["-C", repo, "merge", "--no-ff", "--no-edit", branch]) do
      {:ok, output} ->
        {:ok, output}

      {:error, output} ->
        # A non-zero exit is a CONFLICT only when git left a merge in progress. Anything
        # else (locked or corrupt index, missing object, `--no-ff` refused by policy)
        # is a failure the operator must diagnose, not a conflict to resolve by hand.
        if merge_in_progress?(repo),
          do: {:error, {:merge_conflict, output}},
          else: {:error, {:merge_failed, output}}
    end
  end

  defp merge_in_progress?(repo) do
    match?({:ok, _}, run(["-C", repo, "rev-parse", "-q", "--verify", "MERGE_HEAD"]))
  end

  @doc """
  Turn a failed `merge/2` into the `Error` a caller reports, aborting a conflicted
  merge first. If the abort itself fails the merge is still in place, so that is
  reported (`:merge_failed`, carrying the conflict output) instead of a conflict
  claim that implies the repo was restored.
  """
  @spec merge_error(String.t(), String.t(), {:merge_conflict | :merge_failed, String.t()}) ::
          Error.t()
  def merge_error(repo, branch, {:merge_conflict, output}) do
    case merge_abort(repo) do
      :ok ->
        Error.new(:merge_conflict, "merge produced conflicts", %{branch: branch, output: output})

      {:error, %Error{} = abort} ->
        Error.new(:merge_failed, "merge conflicted and could not be aborted", %{
          branch: branch,
          output: output,
          abort: abort.message
        })
    end
  end

  def merge_error(_repo, branch, {:merge_failed, output}),
    do: Error.new(:merge_failed, "git merge failed", %{branch: branch, output: output})

  @doc """
  Publish `branch` to `remote` from the checkout at `path`. The remote name is
  chosen by the server (never a caller) and prompts are disabled so missing
  credentials fail rather than hang waiting for a terminal that does not exist.
  Not time-bounded: a remote that accepts the connection and then stalls blocks
  the caller until git gives up.
  """
  @spec push(String.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def push(path, remote, branch) do
    args = ["-C", path, "push", remote, "refs/heads/#{branch}:refs/heads/#{branch}"]

    case System.cmd("git", args, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error,
         Error.new(:push_failed, "git push to #{remote} failed", %{
           remote: remote,
           branch: branch,
           exit_code: code,
           output: String.trim(output)
         })}
    end
  end

  @spec merge_abort(String.t()) :: :ok | {:error, Error.t()}
  def merge_abort(repo) do
    run(["-C", repo, "merge", "--abort"]) |> as_ok() |> tag_error(:merge_failed)
  end

  @spec delete_branch(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_branch(repo, branch) do
    run(["-C", repo, "branch", "-D", branch]) |> as_ok() |> tag_error(:git_failed)
  end

  # ---------------------------------------------------------------------

  defp run(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp as_ok({:ok, _output}), do: {:ok, :ok}
  defp as_ok({:error, reason}), do: {:error, reason}

  defp map_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_ok({:error, _} = err, _fun), do: err

  defp tag_error({:ok, :ok}, _code), do: :ok
  defp tag_error({:ok, value}, _code), do: {:ok, value}

  defp tag_error({:error, reason}, code),
    do: {:error, Error.new(code, "git command failed", %{reason: reason})}
end
