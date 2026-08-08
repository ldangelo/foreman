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

  @doc """
  Helper for callers that want retry-on-transient semantics with Default.

  Mirrors the public contract of `ForemanServer.VcsAdapter.run/4` but
  dispatches `VcsOperationStarted`/`Completed`/`Failed` events.
  """
  @spec run(:clone | :branch | :create_pr, [term()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(fun, args, opts \\ []) do
    ForemanServer.VcsAdapter.run(__MODULE__, fun, args, opts)
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

  defp emit_started(operation_id, operation_type, target) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:start",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.start",
      payload: %{operation_id: operation_id, operation_type: operation_type, target: target}
    })
  end

  defp emit_completed(operation_id, operation_type, target, result) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:complete",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.complete",
      payload: %{
        operation_id: operation_id,
        operation_type: operation_type,
        target: target,
        result: result
      }
    })
  end

  defp emit_failed(operation_id, operation_type, target, error, retries) do
    operation_id = to_string(operation_id)
    target = to_string(target)

    CommandGateway.dispatch_system(%{
      command_id: "vcs_operation:#{operation_id}:fail",
      aggregate_id: "vcs_operation:#{operation_id}",
      type: "vcs_operation.fail",
      payload: %{
        operation_id: operation_id,
        operation_type: operation_type,
        target: target,
        error: error,
        retries: retries
      }
    })
  end
end
