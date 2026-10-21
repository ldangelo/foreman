defmodule ForemanServer.PrAssociate do
  @moduledoc """
  TRD-016: PR association module.

  Stores a `run_id` -> `pr_url` association by emitting a `PrAssociated`
  event through `CommandRouter`. The association itself is append-only
  in the event log; the projection store derives the canonical
  mapping.

  ## API

    * `store/2` — dispatch the `pr.associate` command. Returns
      `{:ok, pr_association_id}` on success.
    * `lookup/1` — read the current association for a run from
      `ProjectionStore`. Returns `{:ok, %{run_id:, pr_url:, pr_number:,
      associated_at:}}` or `{:error, :not_found}`.

  PR URL parsing extracts a `pr_number` (e.g. `https://github.com/o/r/pull/42`
  -> 42) which is stored on the event.
  """

  alias ForemanServer.CommandGateway

  require Logger

  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Associate `run_id` with `pr_url`. Dispatches a `pr.associate` command
  through `CommandRouter`; on success returns `{:ok, pr_association_id}`
  where `pr_association_id == run_id` (one association per run and repository).

  `repo_id` is `nil` for the run's primary repository (stream
  `pr_association:<run_id>`, no `repo_id` on the event); any other repository
  gets its own stream `pr_association:<run_id>:<repo_id>` and the event carries
  `repo_id`.
  """
  @spec store(String.t(), String.t(), String.t() | nil) :: result
  def store(run_id, pr_url, repo_id \\ nil)

  def store(run_id, pr_url, repo_id)
      when is_binary(run_id) and is_binary(pr_url) and (is_nil(repo_id) or is_binary(repo_id)) do
    with :ok <- validate_run_id(run_id),
         :ok <- validate_pr_url(pr_url),
         :ok <- validate_repo_id(repo_id) do
      payload = %{
        run_id: run_id,
        pr_url: pr_url,
        pr_number: extract_pr_number(pr_url),
        associated_at: System.system_time(:millisecond)
      }

      payload = if repo_id, do: Map.put(payload, :repo_id, repo_id), else: payload

      command = %{
        type: "pr.associate",
        aggregate_id: ForemanServer.Aggregates.PrAssociation.stream_id(run_id, repo_id),
        payload: payload
      }

      case CommandGateway.dispatch_system(command) do
        {:ok, _event_spec} -> {:ok, run_id}
        {:error, reason} = err -> err_with_log(reason, run_id, pr_url, err)
      end
    end
  end

  def store(_, _, _), do: {:error, :invalid_arguments}

  @doc """
  Look up the current PR association for `run_id` from `ProjectionStore`.

  Returns `{:ok, association}` — a plain projection map, not a
  `%PrAssociated{}`; the projection store never builds the struct — or
  `{:error, :not_found}`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(run_id) when is_binary(run_id) do
    ForemanServer.ProjectionStore.pr_association(run_id)
  end

  def lookup(_), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp validate_repo_id(nil), do: :ok
  defp validate_repo_id(id) when byte_size(id) > 0, do: :ok
  defp validate_repo_id(_), do: {:error, :invalid_repo_id}

  defp validate_run_id(run_id) when byte_size(run_id) > 0, do: :ok
  defp validate_run_id(_), do: {:error, :invalid_run_id}

  defp validate_pr_url(url) do
    cond do
      not is_binary(url) -> {:error, :invalid_pr_url}
      byte_size(url) == 0 -> {:error, :invalid_pr_url}
      not String.contains?(url, "://") -> {:error, :invalid_pr_url}
      true -> :ok
    end
  end

  @doc """
  Extracts the PR number from a GitHub-style PR URL.
  Returns `nil` if the URL does not match the expected pattern.
  """
  @spec extract_pr_number(String.t()) :: non_neg_integer() | nil
  def extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)(?:\D|$)}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  def extract_pr_number(_), do: nil

  defp err_with_log(reason, run_id, pr_url, err) do
    Logger.warning(
      "PrAssociate.store/2 failed: run_id=#{inspect(run_id)} pr_url=#{inspect(pr_url)} reason=#{inspect(reason)}"
    )

    err
  end
end
