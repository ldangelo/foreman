defmodule ForemanServer.Aggregates.PrAssociation do
  @moduledoc """
  TRD-016: PrAssociation aggregate.

  Captures the operator-supplied mapping of a `run_id` to a GitHub pull
  request URL. The aggregate is append-only — re-associating the same
  `run_id` to a new URL emits a fresh `PrAssociated` event rather than
  mutating state. The projection store reads the most recent event to
  derive the canonical mapping.

  ## Stream id

      pr_association:<run_id>

  ## Commands

      * `pr.associate` — emit `PrAssociated` with `run_id`, `pr_url`,
        and `pr_number` (extracted from the URL when not supplied).
  """

  alias ForemanServer.Aggregate

  @behaviour ForemanServer.Aggregate

  defmodule State do
    @moduledoc "Per-run PR association state."
    @enforce_keys [:exists?, :run_id]
    defstruct [
      :exists?,
      :run_id,
      :pr_url,
      :pr_number,
      :associated_at
    ]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      run_id: nil,
      pr_url: nil,
      pr_number: nil,
      associated_at: nil
    }
  end

  @impl true
  def handle_command(_state, %{type: "pr.associate", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, pr_url} <- Aggregate.required_binary(Aggregate.get(payload, :pr_url), :pr_url),
         :ok <- validate_url(pr_url) do
      pr_number = Aggregate.get(payload, :pr_number) || extract_pr_number(pr_url)

      event_payload =
        payload
        |> Map.merge(%{
          run_id: run_id,
          pr_url: pr_url,
          pr_number: pr_number,
          associated_at: Aggregate.get(payload, :associated_at, System.system_time(:millisecond))
        })

      {:ok,
       %{
         stream_id: stream_id(run_id),
         event_type: "PrAssociated",
         payload: event_payload
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PrAssociated" ->
        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id) || state.run_id,
            pr_url: Aggregate.get(payload, :pr_url) || state.pr_url,
            pr_number: Aggregate.get(payload, :pr_number) || state.pr_number,
            associated_at: Aggregate.get(payload, :associated_at) || state.associated_at
        }

      _ ->
        state
    end
  end

  @doc "Build the stream id for a given run_id."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(run_id) when is_binary(run_id), do: "pr_association:#{run_id}"

  defp validate_url(url) when is_binary(url) do
    cond do
      byte_size(url) == 0 -> {:error, {:missing_or_invalid, :pr_url}}
      not String.contains?(url, "://") -> {:error, {:missing_or_invalid, :pr_url}}
      true -> :ok
    end
  end

  defp extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)(?:\D|$)}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
