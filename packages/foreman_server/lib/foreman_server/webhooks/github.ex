defmodule ForemanServer.Webhooks.Github do
  @moduledoc """
  TRD-017: Adapter that turns GitHub webhook payloads into
  `run.pr.update` commands and dispatches them through
  `ForemanServer.CommandRouter`.

  ## Supported events

    * `pull_request` action `closed` + `merged: true`  — PR merged.
    * `pull_request` action `closed` + `merged: false` — PR closed.
    * `pull_request` action `reopened`                 — PR back to open.
    * `pull_request` with `mergeable_state` `dirty`/`blocked` — sync conflict.

  ## Example

      iex> Webhooks.Github.process(%{
      ...>   "action" => "closed",
      ...>   "pull_request" => %{"merged" => true, "html_url" => "...", "head" => %{"sha" => "abc"}, "base" => %{"ref" => "main"}}
      ...> })
      :ok
  """

  alias ForemanServer.CommandGateway

  require Logger

  @merged_status :merged
  @closed_status :closed
  @open_status :open
  @conflicted_status :conflicted

  @doc """
  Translate a GitHub webhook payload into a `run.pr.update` command
  and dispatch it through the CommandRouter.

  Returns one of:

    * `:ok` — payload successfully routed (or was not actionable).
    * `:ignored` — payload was missing required fields (`run_id`/`pr_url`)
      and was discarded (typically because the webhook fired before the
      run was associated).
    * `{:error, reason}` — dispatcher returned an error tuple.
  """
  def process(payload) when is_map(payload) do
    case build_command(payload) do
      {:ok, command} ->
        case CommandGateway.dispatch_system(command) do
          {:ok, _event_spec} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :ignored ->
        :ignored
    end
  end

  def process(_), do: :ignored

  @doc """
  Pure-translation variant that returns the command map without
  dispatching. Useful for tests and for batched ingestion paths.
  """
  def build_command(payload) when is_map(payload) do
    case extract(payload) do
      {:ok, fields} ->
        {:ok,
         %{
           type: "run.pr.update",
           aggregate_id: "run:#{fields.run_id}",
           payload: fields
         }}

      :ignore ->
        :ignore

      :missing ->
        :ignored
    end
  end

  defp extract(%{"action" => action, "pull_request" => pr} = payload) do
    case derive_status(action, pr) do
      nil ->
        :ignore

      status ->
        case required_fields(payload, pr) do
          {:ok, run_id} ->
            {:ok,
             %{
               run_id: run_id,
               pr_url: pr["html_url"],
               pr_status: status,
               head_sha: get_in(pr, ["head", "sha"]),
               base_branch: get_in(pr, ["base", "ref"]),
               phase: status_to_phase(status)
             }}

          :missing ->
            :missing
        end
    end
  end

  defp extract(_), do: :ignore

  defp derive_status("closed", %{"merged" => true}), do: @merged_status
  defp derive_status("closed", _), do: @closed_status
  defp derive_status("reopened", _), do: @open_status

  defp derive_status(_action, %{"mergeable_state" => state})
       when state in ["dirty", "blocked"],
       do: @conflicted_status

  defp derive_status(_action, _), do: nil

  defp required_fields(payload, pr) do
    cond do
      not is_binary(pr["html_url"]) -> :missing
      true -> {:ok, find_run_id(payload)}
    end
  end

  defp find_run_id(%{"run_id" => id}) when is_binary(id), do: id
  defp find_run_id(%{"sender" => %{"login" => login}}) when is_binary(login), do: "run:#{login}"
  defp find_run_id(_), do: nil

  defp status_to_phase(:merged), do: "merge_pending"
  defp status_to_phase(:open), do: "pr_open"
  defp status_to_phase(:closed), do: "pr_closed"
  defp status_to_phase(:conflicted), do: "pr_conflict"
  defp status_to_phase(_), do: "pr_open"
end
