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
  alias ForemanServer.Exec.Git

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

    case reuse_existing_worktree(repo_path, worktree_path, branch) do
      {:ok, _matched_branch} ->
        result = %{
          path: worktree_path,
          base: base,
          branch: branch,
          output: "",
          reused: true
        }

        emit_completed(operation_id, "worktree_create", target, result, metadata)
        {:ok, result}

      {:error, reason} ->
        emit_failed(operation_id, "worktree_create", target, reason, 0, metadata)
        {:error, reason}

      :create ->
        create_fresh_worktree(
          repo_path,
          worktree_path,
          branch,
          base,
          operation_id,
          target,
          metadata
        )
    end
  end

  # `git worktree add` on a path that is already a registered worktree fails
  # with exit 128 ("already exists"), which used to fail a relaunched run even
  # though the worktree it wanted is sitting right there — with any
  # uncommitted phase work in it. So probe the path first and only reach for
  # `git worktree add` when there is genuinely nothing usable there.
  #
  #   * nothing at the path, or an existing EMPTY directory -> `:create`. An
  #     empty directory is what a half-finished create leaves behind and
  #     `git worktree add` accepts one, so it must stay creatable.
  #   * registered worktree already on the requested branch (a `nil` request
  #     matches a detached worktree) -> `{:ok, branch}`; the caller returns it
  #     as reused WITHOUT resetting, checking out, cleaning or re-running the
  #     `.beads/` sparse-checkout exclusion, so local work survives. A
  #     registration whose directory is no longer a working checkout (its
  #     `gitdir` pointer was removed, which git flags `prunable`) is refused.
  #   * anything else at that path -> a typed `{:worktree_path_unusable, path,
  #     reason}`. The branch check stays strict: a worktree on an unrelated
  #     branch is NOT reused.
  defp reuse_existing_worktree(repo_path, worktree_path, branch) do
    cond do
      not File.exists?(worktree_path) ->
        :create

      empty_dir?(worktree_path) ->
        :create

      true ->
        classify_registered_worktree(repo_path, worktree_path, branch)
    end
  end

  # Only a directory we could hand to `git worktree add` counts as empty; a
  # file, or a path we cannot read, is classified by git instead.
  defp empty_dir?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      {:ok, _entries} -> false
      {:error, _reason} -> false
    end
  end

  defp classify_registered_worktree(repo_path, worktree_path, branch) do
    case Git.worktree_list(repo_path) do
      {:ok, worktrees} ->
        case find_registered(worktrees, worktree_path) do
          nil ->
            {:error, {:worktree_path_unusable, worktree_path, :not_a_git_worktree}}

          %{branch: registered_branch} ->
            if registered_branch == branch do
              case usable_checkout?(worktree_path) do
                {:unusable, reason} ->
                  {:error, {:worktree_path_unusable, worktree_path, reason}}

                :usable ->
                  case checkout_branch(worktree_path) do
                    ^branch ->
                      {:ok, registered_branch}

                    checkout_branch ->
                      {:error,
                       {:worktree_path_unusable, worktree_path,
                        {:branch_mismatch, checkout_branch}}}
                  end
              end
            else
              {:error,
               {:worktree_path_unusable, worktree_path, {:branch_mismatch, registered_branch}}}
            end
        end

      {:error, reason} ->
        {:error, {:worktree_path_unusable, worktree_path, {:worktree_list_failed, reason}}}
    end
  end

  # A worktree stays registered with git after its `gitdir` pointer is deleted:
  # `worktree list` still reports it (flagged `prunable`, a line
  # `Git.worktree_list/1` does not surface) while the directory is an ordinary
  # directory again — and inside the repo it silently reads as the parent
  # checkout. Ask git which admin dir the path belongs to and require it to be
  # the one recorded in that checkout, so a stale registration is reported
  # rather than reused.
  #
  # A checkout interrupted part-way (the process died inside `git worktree
  # add`) is registered, points at its admin dir and is on the right branch,
  # but git writes the admin dir's `index` only when the checkout finishes: with
  # none, the files that were never written read as deleted, and the phase
  # commit (`git add -A`) would record those deletions. Such a path is refused
  # rather than handed to an agent.
  defp usable_checkout?(worktree_path) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "rev-parse", "--absolute-git-dir"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        admin_dir = canonicalize(String.trim(output))

        cond do
          recorded_admin_dir(worktree_path) != admin_dir ->
            {:unusable, :worktree_checkout_broken}

          not File.exists?(Path.join(admin_dir, "index")) ->
            {:unusable, :worktree_checkout_incomplete}

          true ->
            :usable
        end

      {_output, _code} ->
        {:unusable, :not_a_git_worktree}
    end
  end

  # Read the `gitdir:` pointer the checkout itself carries. `nil` when there is
  # nothing to read, which means the directory is not a working checkout.
  defp recorded_admin_dir(worktree_path) do
    with {:ok, contents} <- File.read(Path.join(worktree_path, ".git")),
         ["gitdir: " <> target] <- String.split(contents, "\n", parts: 2, trim: true) do
      canonicalize(expand_gitdir(target, worktree_path))
    else
      _ -> nil
    end
  end

  # Git resolves a relative `gitdir:` pointer against the directory that holds
  # the `.git` file, not against the process cwd — Git 2.48 and later write
  # relative pointers when `worktree.useRelativePaths` is set.
  defp expand_gitdir(target, worktree_path) do
    target = String.trim(target)

    if Path.type(target) == :absolute do
      target
    else
      # Git resolves a relative pointer against the directory holding the
      # `.git` file; `Path.expand/2` also collapses the `..` segments such a
      # pointer carries, so the result stays comparable to git's own answer.
      Path.expand(target, worktree_path)
    end
  end

  # The branch the checkout itself is on, read from its own HEAD. `nil` when
  # the checkout is detached. The registry entry can be stale — a checkout
  # whose `gitdir` pointer was repointed keeps the registration it had — so
  # the checkout is the authority on what a command run in that directory
  # would actually see.
  defp checkout_branch(worktree_path) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "symbolic-ref", "-q", "--short", "HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, _code} -> nil
    end
  end

  # Git reports worktree paths resolved through symlinks (e.g. `/private/var/…`
  # for a `/var/…` request on macOS), so compare canonical forms; an
  # unresolvable path simply never matches.
  defp find_registered(worktrees, worktree_path) do
    target = canonicalize(worktree_path)
    Enum.find(worktrees, &(canonicalize(&1.path) == target))
  end

  defp create_fresh_worktree(
         repo_path,
         worktree_path,
         branch,
         base,
         operation_id,
         target,
         metadata
       ) do
    args = Git.worktree_add_args(repo_path, worktree_path, branch, base)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        case exclude_dotbeads(worktree_path) do
          :ok ->
            result = %{
              path: worktree_path,
              base: base,
              branch: branch,
              output: output,
              reused: false
            }

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
    case Git.worktree_list(repo_path) do
      {:ok, worktrees} ->
        target = canonicalize(worktree_path)
        Enum.any?(worktrees, &(canonicalize(&1.path) == target))

      {:error, _reason} ->
        true
    end
  end

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
