defmodule ForemanServer.VcsAdapter.Default do
  @moduledoc """
  TRD-018: Default VCS adapter for GitHub.

  This implementation shells out to the `git` and `gh` CLIs and routes
  results through the standard tagged-tuple contract. It is intentionally
  pure with respect to retry: callers compose it with
  `ForemanServer.VcsAdapter.run/4` to obtain retry-on-transient semantics.

  All operations route through `CommandRouter` for event emission
  (`VcsOperationStarted` → `VcsOperationCompleted` | `VcsOperationFailed`).
  """

  @behaviour ForemanServer.VcsAdapter

  alias ForemanServer.CommandGateway

  @impl true
  def clone(url, opts) do
    operation_id = Keyword.get(opts, :operation_id, "clone-#{System.unique_integer([:positive])}")
    target = Keyword.get(opts, :target, "/tmp/vcs-#{operation_id}")

    emit_started(operation_id, "clone", target)
    cmd = ~c"git clone --depth 1 #{url} #{target}"

    case System.cmd("git", String.split(cmd |> List.to_string())) do
      {_output, 0} ->
        result = %{path: target}
        emit_completed(operation_id, "clone", target, result)
        {:ok, result}

      {output, code} ->
        reason = classify_git_error(code, output)
        emit_failed(operation_id, "clone", target, reason, 0)
        reason
    end
  end

  @impl true
  def branch(path, name) do
    operation_id = "branch-#{System.unique_integer([:positive])}"
    target = "#{path}:#{name}"

    emit_started(operation_id, "branch", target)

    case System.cmd("git", ["-C", path, "checkout", "-b", name]) do
      {_output, 0} ->
        result = %{branch: name}
        emit_completed(operation_id, "branch", target, result)
        {:ok, result}

      {output, code} ->
        reason = classify_git_error(code, output)
        emit_failed(operation_id, "branch", target, reason, 0)
        reason
    end
  end

  @impl true
  def create_pr(path, opts) do
    operation_id = Keyword.get(opts, :operation_id, "pr-#{System.unique_integer([:positive])}")
    title = Keyword.get(opts, :title, "Auto PR")
    body = Keyword.get(opts, :body, "")
    base = Keyword.get(opts, :base, "main")
    target = "#{path}:#{title}"

    emit_started(operation_id, "create_pr", target)

    case System.cmd("gh", ["pr", "create", "--title", title, "--body", body, "--base", base],
           cd: path
         ) do
      {output, 0} ->
        {url, number} = parse_pr_output(output)
        result = %{url: url, number: number}
        emit_completed(operation_id, "create_pr", target, result)
        {:ok, result}

      {output, code} ->
        reason = classify_gh_error(code, output)
        emit_failed(operation_id, "create_pr", target, reason, 0)
        reason
    end
  end

  @impl true
  def create_worktree(repo_path, worktree_path, opts) do
    operation_id = Keyword.fetch!(opts, :operation_id)
    base = Keyword.fetch!(opts, :base)
    branch = Keyword.fetch!(opts, :branch)
    project_id = Keyword.fetch!(opts, :project_id)
    run_id = Keyword.fetch!(opts, :run_id)
    phase_id = Keyword.fetch!(opts, :phase_id)

    target = scrubbed_target(repo_path, worktree_path, base)
    metadata = %{project_id: project_id, run_id: run_id, phase_id: phase_id}

    emit_started(operation_id, "worktree_create", target, metadata)

    base_args =
      if branch_exists?(repo_path, branch),
        do: [worktree_path, branch],
        else: branch_args(branch) ++ [worktree_path, base]

    args = ["-C", repo_path, "worktree", "add"] ++ base_args

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        case exclude_dotbeads(worktree_path) do
          :ok ->
            result = %{path: worktree_path, base: base, branch: branch, output: output}
            emit_completed(operation_id, "worktree_create", target, result, metadata)
            {:ok, result}

          {:error, exclude_reason} ->
            # Best-effort cleanup: the worktree exists but the exclusion failed.
            # Roll back so we don't leave the caller with a worktree that
            # violates the no-`.beads/` contract.
            _ =
              System.cmd("git", ["-C", repo_path, "worktree", "remove", "--force", worktree_path],
                stderr_to_stdout: true
              )

            _ = System.cmd("git", ["-C", repo_path, "worktree", "prune"], stderr_to_stdout: true)
            reason = {:worktree_beads_exclusion_failed, exclude_reason}
            emit_failed(operation_id, "worktree_create", target, reason, 0, metadata)
            {:error, reason}
        end

      {output, code} ->
        reason = {:git_worktree_create_failed, code, output}
        emit_failed(operation_id, "worktree_create", target, reason, 0, metadata)
        {:error, reason}
    end
  end

  # Apply a per-worktree sparse-checkout exclusion so a tracked `.beads/`
  # in the source repository is NOT materialized into the fresh worktree.
  # The user-guide contract requires "The worktree must not bring its own
  # `.beads/` into the phase" — naive `rm -rf` would leave the worktree
  # dirty with staged-visible deletions, so we use non-cone sparse-checkout
  # instead: `.beads/` is excluded from BOTH the working tree and the
  # index, leaving `git status --porcelain` clean while still satisfying
  # the no-local-`.beads/` invariant that the Beads skill depends on.
  #
  # Linked worktrees have `<worktree>/.git` as a FILE pointing back at
  # the parent repo's gitdir, so we MUST route the patterns through git
  # itself (`sparse-checkout set --no-cone`) rather than writing to
  # `<worktree>/.git/info/sparse-checkout` directly.
  defp exclude_dotbeads(worktree_path) do
    with :ok <- run_git(worktree_path, ["sparse-checkout", "init", "--no-cone"]),
         :ok <-
           run_git(worktree_path, [
             "sparse-checkout",
             "set",
             "--no-cone",
             "/*",
             "!/.beads/",
             "!/.beads/**"
           ]) do
      if File.exists?(Path.join(worktree_path, ".beads")) do
        {:error, {:dotbeads_still_present, worktree_path}}
      else
        :ok
      end
    end
  end

  defp run_git(cwd, args) do
    case System.cmd("git", ["-C", cwd] ++ args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:git_cmd_failed, args, code, output}}
    end
  end

  @impl true
  def clean_worktree(worktree_path, opts) do
    operation_id = Keyword.fetch!(opts, :operation_id)
    repo_path = Keyword.fetch!(opts, :repo_path)
    project_id = Keyword.fetch!(opts, :project_id)
    run_id = Keyword.fetch!(opts, :run_id)
    phase_id = Keyword.fetch!(opts, :phase_id)

    target = scrubbed_target(repo_path, worktree_path)
    metadata = %{project_id: project_id, run_id: run_id, phase_id: phase_id}

    emit_started(operation_id, "worktree_clean", target, metadata)

    cond do
      absent?(worktree_path, repo_path) ->
        result = %{path: worktree_path, cleaned?: true, noop?: true}
        emit_completed(operation_id, "worktree_clean", target, result, metadata)
        {:ok, result}

      true ->
        case System.cmd(
               "git",
               ["-C", repo_path, "worktree", "remove", worktree_path],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            System.cmd(
              "git",
              ["-C", repo_path, "worktree", "prune"],
              stderr_to_stdout: true
            )

            result = %{path: worktree_path, cleaned?: true, noop?: false, output: output}
            emit_completed(operation_id, "worktree_clean", target, result, metadata)
            {:ok, result}

          {output, code} ->
            reason = {:git_worktree_clean_failed, code, output}
            emit_failed(operation_id, "worktree_clean", target, reason, 0, metadata)

            {:error, reason}
        end
    end
  end

  @doc """
  Helper for callers that want retry-on-transient semantics with Default.

  Mirrors the public contract of `ForemanServer.VcsAdapter.run/4` but
  dispatches `VcsOperationStarted`/`Completed`/`Failed` events.
  """
  @spec run(
          :clone | :branch | :create_pr | :create_worktree | :clean_worktree,
          [term()],
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def run(fun, args, opts \\ []) do
    ForemanServer.VcsAdapter.run(__MODULE__, fun, args, opts)
  end

  @doc """
  Build the scrubbed dispatch target string. Paths are reduced to
  `Path.basename/1` so telemetry and event payloads do not leak the
  full absolute working directory. The extra suffix (passed positionally)
  is appended verbatim. Returns `"<repo_basename>:<worktree_basename>"`
  when no suffix is supplied.
  """
  def scrubbed_target(repo_path, worktree_path, extra \\ nil) do
    base_segment = Path.basename(repo_path)
    worktree_segment = Path.basename(worktree_path)

    case extra do
      nil -> "#{base_segment}:#{worktree_segment}"
      "" -> "#{base_segment}:#{worktree_segment}"
      suffix -> "#{base_segment}:#{worktree_segment}:#{suffix}"
    end
  end

  # Canonicalize a path so callers can compare against paths recorded
  # by `git worktree list --porcelain`. The target filesystem may live
  # behind a symlink (macOS `/tmp` -> `/private/var/folders/...`) so a
  # straight `Path.expand/1` returns the un-resolved form. Since the
  # worktree path itself may be absent when this is called (the
  # stale-registration probe), we cannot call `File.realpath!/1` on it
  # directly. Walk the existing parent via `File.read_link/1`
  # (POSIX / Erlang stdlib, no shell-out) and append the basename;
  # fall back to `Path.expand/1` if the parent is missing.
  def canonicalize(path) do
    parent = Path.dirname(path)
    base = Path.basename(path)

    if File.exists?(parent) do
      Path.join(resolve_symlinks(parent), base)
    else
      Path.expand(path)
    end
  end

  # Recursively resolve symlinks for an existing path component by
  # component. Stays inside Erlang's stdlib so behavior is identical
  # across macOS, Linux, and any POSIX-like host we ship to. Walks
  # `path` left-to-right, replacing each symlink with `File.read_link/1`
  # and continuing against the resolved target. Returns the absolute
  # resolved form (joining against `cwd` if a relative path falls out).
  defp resolve_symlinks(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("", fn segment, acc ->
      case acc do
        "" ->
          segment

        _ ->
          candidate = Path.join(acc, segment)

          case File.read_link(candidate) do
            {:ok, target} -> Path.expand(target, Path.dirname(candidate))
            _ -> candidate
          end
      end
    end)
  end

  # Returns true only when the worktree path is absent AND the
  # `git worktree list` registry does not record it. The strict AND
  # prevents silently nooping on a stale registration: if the path was
  # removed out-of-band but `git worktree list` still lists it, the
  # caller MUST run `git worktree remove` (which will fail and surface
  # the dirty state) so the operator notices the stale entry.
  defp absent?(worktree_path, repo_path) do
    not File.exists?(worktree_path) and not registered?(worktree_path, repo_path)
  end

  # Parses `git worktree list --porcelain` output. Each record begins
  # with `worktree <abs-path>` on its own line. Both the target and
  # the recorded path are canonicalized via `canonicalize/1` so the
  # macOS `/tmp` -> `/private/var/...` symlink resolution does not
  # produce a false noop. On `git worktree list` failure we
  # conservatively treat the worktree as registered — false-noop is
  # worse than a clean attempt that surfaces the underlying error.
  defp registered?(worktree_path, repo_path) do
    case System.cmd(
           "git",
           ["-C", repo_path, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        target = canonicalize(worktree_path)

        match_path = fn line ->
          case String.split(line, " ", parts: 2) do
            ["worktree", path] -> canonicalize(path) == target
            _ -> false
          end
        end

        Enum.any?(String.split(output, "\n", trim: true), match_path)

      _ ->
        true
    end
  end

  defp branch_exists?(_repo_path, nil), do: false

  defp branch_exists?(repo_path, branch) do
    case System.cmd(
           "git",
           ["-C", repo_path, "rev-parse", "--verify", "--quiet", "refs/heads/" <> branch],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp branch_args(nil), do: []
  defp branch_args(branch), do: ["-b", branch]

  defp parse_pr_output(output) do
    case Regex.run(~r|https://github\.com/[^/]+/[^/]+/pull/(\d+)|, output) do
      [url, num] -> {url, String.to_integer(num)}
      _ -> {output |> String.trim() |> String.split("\n") |> List.last(), 0}
    end
  end

  defp classify_git_error(128, _output), do: {:transient, "git error 128"}

  defp classify_git_error(_code, output) do
    cond do
      output =~ ~r/Authentication failed/ -> :auth
      output =~ ~r/Repository not found/ -> :not_found
      output =~ ~r/bad config|fatal: invalid/ -> :invalid
      true -> {:transient, "git failure"}
    end
  end

  defp classify_gh_error(4, _output), do: :auth
  defp classify_gh_error(8, _output), do: :not_found

  defp classify_gh_error(_code, output) do
    cond do
      output =~ ~r/could not resolve|network/i -> {:transient, "gh transient"}
      output =~ ~r/GraphQL:.*not found/i -> :not_found
      true -> {:transient, "gh failure"}
    end
  end

  # Emit helpers accept an optional metadata map as the last argument.
  # Merge order is `Map.merge(metadata, core)` so core fields
  # (`operation_id`, `operation_type`, `target`, `result`/`error`,
  # `retries`) always win on key collision — metadata cannot widen or
  # shadow the canonical envelope.

  defp emit_started(operation_id, operation_type, target, metadata \\ %{}) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:start",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.start",
      payload:
        Map.merge(
          metadata,
          %{operation_id: operation_id, operation_type: operation_type, target: target}
        )
    })
  end

  defp emit_completed(operation_id, operation_type, target, result, metadata \\ %{}) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:complete",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.complete",
      payload:
        Map.merge(
          metadata,
          %{
            operation_id: operation_id,
            operation_type: operation_type,
            target: target,
            result: result
          }
        )
    })
  end

  defp emit_failed(operation_id, operation_type, target, error, retries, metadata \\ %{}) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:fail",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.fail",
      payload:
        Map.merge(
          metadata,
          %{
            operation_id: operation_id,
            operation_type: operation_type,
            target: target,
            error: error,
            retries: retries
          }
        )
    })
  end
end
