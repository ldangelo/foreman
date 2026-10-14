defmodule ForemanServer.Webhooks.Github do
  @moduledoc """
  TRD-017: Adapter that turns GitHub `pull_request` webhook payloads into
  `run.pr.update` commands and dispatches them through
  `ForemanServer.CommandGateway`.

  Only payloads whose signature `ForemanServerWeb.Plugs.VerifyGithubSignature`
  already verified reach this module.

  A delivery is attributed to runs by PR URL: every run whose recorded PR
  association is the delivery's `pull_request.html_url` receives the update. GitHub
  sends events for every PR in the repository, so a PR no run owns is `:ignored`
  (HTTP 202), not an error. Nothing in the payload names a run, and nothing the
  sender controls selects one.

  Handled `pull_request` actions:

    * `closed` with `merged: true`  — `:merged`.
    * `closed` with `merged: false` — `:closed`.
    * `reopened`                    — `:open`.
    * any action while `mergeable_state` is `dirty` — `:conflicted`.

  `blocked` is deliberately not a conflict: it means required checks or reviews are
  pending, which is the normal state of a healthy open PR.

  The command is built by `ForemanServer.PrUpdate`, shared with `PrMonitor`. Its id
  is derived from the observed status and head SHA, so a redelivery (GitHub retries)
  and a poll reporting the same state are deduplicated by the router.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrUpdate
  alias ForemanServer.ProjectionStore

  @type result :: :ok | :ignored | {:error, term()}

  @doc """
  Translate a verified webhook payload and dispatch one `run.pr.update` per owning
  run.

  Returns `:ok` when every dispatch succeeded, `:ignored` when the payload is not a
  handled event or no run owns the PR, and `{:error, reason}` for the first failure.
  """
  @spec process(term()) :: result()
  def process(payload) when is_map(payload) do
    case build_commands(payload) do
      {:ok, commands} -> dispatch_all(commands)
      :ignored -> :ignored
      {:error, _reason} = error -> error
    end
  end

  def process(_other), do: :ignored

  @doc """
  Pure-translation variant that returns the commands without dispatching.
  """
  @spec build_commands(term()) :: {:ok, [map()]} | :ignored | {:error, term()}
  def build_commands(%{"action" => action, "pull_request" => %{"html_url" => pr_url} = pr})
      when is_binary(pr_url) and pr_url != "" do
    case status(action, pr) do
      nil -> :ignored
      status -> commands_for(pr_url, status, pr)
    end
  end

  def build_commands(_other), do: :ignored

  defp commands_for(pr_url, status, pr) do
    with {:ok, observed} <- observation(status, pr) do
      case ProjectionStore.run_ids_for_pr_url(pr_url) do
        [] ->
          :ignored

        run_ids ->
          run_ids
          |> Enum.map(&PrUpdate.command(&1, pr_url, observed))
          |> collect()
      end
    end
  end

  # GitHub always sends these on a `pull_request` event; one missing is a payload
  # we do not understand, reported by name rather than guessed.
  defp observation(status, pr) do
    with {:ok, head_sha} <- required(pr, ["head", "sha"], :head_sha),
         {:ok, head_branch} <- required(pr, ["head", "ref"], :head_branch),
         {:ok, base_branch} <- required(pr, ["base", "ref"], :base_branch) do
      {:ok,
       %PrStatus{
         status: status,
         head_sha: head_sha,
         head_branch: head_branch,
         base_branch: base_branch
       }}
    end
  end

  defp required(pr, path, name) do
    case get_in(pr, path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:pr_payload_missing, name}}
    end
  end

  defp collect(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, command}, {:ok, acc} -> {:cont, {:ok, [command | acc]}}
      {:error, _} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, commands} -> {:ok, Enum.reverse(commands)}
      {:error, _} = error -> error
    end
  end

  defp dispatch_all(commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case CommandGateway.dispatch_system(command) do
        {:ok, _event_spec} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        {:error, reason, _detail} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp status("closed", %{"merged" => true}), do: :merged
  defp status("closed", _pr), do: :closed
  defp status("reopened", _pr), do: :open
  defp status(_action, %{"mergeable_state" => "dirty"}), do: :conflicted
  defp status(_action, _pr), do: nil
end
