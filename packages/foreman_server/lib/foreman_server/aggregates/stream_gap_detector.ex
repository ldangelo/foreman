defmodule ForemanServer.Aggregates.StreamGapDetector do
  @moduledoc """
  TRD-041 / REQ-021: stream-gap detector aggregate.

  Holds a per-stream flag map; the `CommandRouter` consults this map
  before each append and refuses further writes to flagged streams until
  the gap is resolved.

  Detection happens elsewhere (a reconciliation job comparing the
  projection store version to the actual stream version in the event
  log). This aggregate is the policy layer: it accepts detection events,
  surfaces `StreamGapDetected`, and provides `flagged?/1` for the router.

  ## Stream id

      stream_gap:<stream_id>

  ## Commands

      * `stream_gap.report`  — flag a stream; emits `StreamGapDetected`
      * `stream_gap.resolve` — unflag a stream; emits `StreamGapResolved`
  """

  alias ForemanServer.Aggregate

  @behaviour ForemanServer.Aggregate

  defmodule State do
    @moduledoc "Per-stream gap detector state."
    @enforce_keys [:exists?, :stream_id]
    defstruct [
      :exists?,
      :stream_id,
      :status,
      :detected_at_ms,
      :expected_version,
      :projected_version,
      :resolved_at_ms
    ]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      stream_id: nil,
      status: "ok",
      detected_at_ms: nil,
      expected_version: nil,
      projected_version: nil,
      resolved_at_ms: nil
    }
  end

  @impl true
  def handle_command(state, %{type: "stream_gap.report", payload: payload}) do
    with {:ok, inner_stream_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :stream_id), :stream_id) do
      if state.status == "gap_detected" do
        {:ok, :already_flagged}
      else
        {:ok,
         %{
           stream_id: stream_id(inner_stream_id),
           event_type: "StreamGapDetected",
           payload:
             payload
             |> Map.put(:stream_id, inner_stream_id)
             |> Map.put(:detected_at_ms, Aggregate.get(payload, :detected_at_ms, now_ms()))
             |> Map.put(:expected_version, Aggregate.get(payload, :expected_version))
             |> Map.put(:projected_version, Aggregate.get(payload, :projected_version))
         }}
      end
    end
  end

  def handle_command(state, %{type: "stream_gap.resolve", payload: payload}) do
    with {:ok, inner_stream_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :stream_id), :stream_id) do
      if state.status != "gap_detected" do
        {:ok, :already_ok}
      else
        {:ok,
         %{
           stream_id: stream_id(inner_stream_id),
           event_type: "StreamGapResolved",
           payload:
             payload
             |> Map.put(:stream_id, inner_stream_id)
             |> Map.put(:resolved_at_ms, Aggregate.get(payload, :resolved_at_ms, now_ms()))
         }}
      end
    end
  end

  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "StreamGapDetected" ->
        %State{
          state
          | exists?: true,
            stream_id: Aggregate.get(payload, :stream_id) || state.stream_id,
            status: "gap_detected",
            detected_at_ms: Aggregate.get(payload, :detected_at_ms) || now_ms(),
            expected_version: Aggregate.get(payload, :expected_version),
            projected_version: Aggregate.get(payload, :projected_version)
        }

      "StreamGapResolved" ->
        %State{
          state
          | exists?: true,
            stream_id: Aggregate.get(payload, :stream_id) || state.stream_id,
            status: "ok",
            resolved_at_ms: Aggregate.get(payload, :resolved_at_ms) || now_ms()
        }

      _ ->
        state
    end
  end

  @doc "Build the stream id for a logical stream."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(stream_id) when is_binary(stream_id), do: "stream_gap:#{stream_id}"

  @doc "Returns true when the stream is currently flagged."
  @spec flagged?(State.t()) :: boolean()
  def flagged?(%State{status: "gap_detected"}), do: true
  def flagged?(_state), do: false

  defp now_ms, do: System.system_time(:millisecond)
end
