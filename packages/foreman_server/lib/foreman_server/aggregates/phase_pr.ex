defmodule ForemanServer.Aggregates.PhasePr do
  @moduledoc """
  Append-only aggregate for phase PR records.

  Each phase records at most one created/reused/noop outcome per deterministic
  command id. The stream is separate from `pr_association:*` so phase PRs never
  drive final-run PR monitor state.
  """

  alias ForemanServer.Aggregate

  @behaviour ForemanServer.Aggregate

  defmodule State do
    @moduledoc "Per-phase PR record state."
    defstruct records: []
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def handle_command(_state, %{type: "phase_pr.record", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         {:ok, phase_name} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_name), :phase_name),
         {:ok, phase_index} <- valid_phase_index(Aggregate.get(payload, :phase_index)),
         {:ok, status} <- valid_status(Aggregate.get(payload, :status)),
         {:ok, base_branch} <-
           Aggregate.required_binary(Aggregate.get(payload, :base_branch), :base_branch),
         {:ok, head_branch} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_branch), :head_branch),
         {:ok, provider} <-
           Aggregate.required_binary(Aggregate.get(payload, :provider), :provider),
         :ok <- validate_url_for_status(status, Aggregate.get(payload, :pr_url)) do
      event_payload = %{
        run_id: run_id,
        phase_id: phase_id,
        phase_index: phase_index,
        phase_name: phase_name,
        status: status,
        pr_url: Aggregate.get(payload, :pr_url),
        pr_number: Aggregate.get(payload, :pr_number),
        base_branch: base_branch,
        head_branch: head_branch,
        provider: provider,
        reason: Aggregate.get(payload, :reason),
        recorded_at:
          Aggregate.get(payload, :recorded_at) || DateTime.to_iso8601(DateTime.utc_now())
      }

      {:ok,
       %{
         stream_id: stream_id(run_id, phase_id),
         event_type: "PhasePrRecorded",
         payload: event_payload
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "PhasePrRecorded" -> %{state | records: state.records ++ [Aggregate.event_payload(event)]}
      _ -> state
    end
  end

  @spec stream_id(String.t(), String.t()) :: String.t()
  def stream_id(run_id, phase_id) when is_binary(run_id) and is_binary(phase_id),
    do: "phase_pr:#{run_id}:#{phase_id}"

  defp valid_phase_index(index) when is_integer(index) and index >= 0, do: {:ok, index}
  defp valid_phase_index(index), do: {:error, {:missing_or_invalid, :phase_index, index}}

  defp valid_status(status) when status in ["created", "existing", "noop"], do: {:ok, status}

  defp valid_status(status) when status in [:created, :existing, :noop],
    do: {:ok, Atom.to_string(status)}

  defp valid_status(status), do: {:error, {:missing_or_invalid, :status, status}}

  defp validate_url_for_status("noop", _url), do: :ok

  defp validate_url_for_status(_status, url) when is_binary(url) and url != "" do
    if String.contains?(url, "://"), do: :ok, else: {:error, {:missing_or_invalid, :pr_url}}
  end

  defp validate_url_for_status(_status, _url), do: {:error, {:missing_or_invalid, :pr_url}}
end
