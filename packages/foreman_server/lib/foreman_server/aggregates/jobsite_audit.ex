defmodule ForemanServer.Aggregates.JobsiteAudit do
  @moduledoc """
  Append-only audit aggregate for remote-jobsite HTTP requests.

  All audit records live on ONE fixed stream, `jobsite_audit:global`
  (`stream_id/0`). The `"jobsite_audit:"` prefix is routed here by
  `CommandRouter.aggregate_module_for/1`; it is deliberately distinct from
  the `"jobsite:"` prefix of the run aggregate (`"jobsite_audit:..."` does
  not start with `"jobsite:"`).

  Command `jobsite.audit.record` is system-only (dispatched through
  `CommandGateway.dispatch_system/2`, not in the operator allowlist) and
  emits `JobsiteRequestAudited`. State only keeps counters; the event
  stream itself is the audit log. Idempotency by `command_id` is handled
  by `CommandRouter`.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.JobsiteRequestAudited

  @stream_id "jobsite_audit:global"
  @outcomes ~w(accepted rejected)

  @doc "The single audit stream id."
  @spec stream_id() :: String.t()
  def stream_id, do: @stream_id

  defmodule State do
    @moduledoc "Counters over the audit stream."
    @enforce_keys [:total, :accepted, :rejected]
    defstruct total: 0, accepted: 0, rejected: 0
  end

  @impl true
  def initial_state, do: %State{total: 0, accepted: 0, rejected: 0}

  # ---------------------------------------------------------------------------
  # apply_event/2
  # ---------------------------------------------------------------------------

  @impl true
  def apply_event(%State{} = state, %JobsiteRequestAudited{outcome: outcome}),
    do: count(state, outcome)

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "JobsiteRequestAudited" ->
        payload = event |> Aggregate.event_payload() |> Map.delete("event_type")

        %JobsiteRequestAudited{outcome: outcome} =
          EventCodec.decode!("JobsiteRequestAudited", payload)

        count(state, outcome)

      _ ->
        state
    end
  end

  defp count(%State{} = s, "accepted"),
    do: %State{s | total: s.total + 1, accepted: s.accepted + 1}

  defp count(%State{} = s, "rejected"),
    do: %State{s | total: s.total + 1, rejected: s.rejected + 1}

  # ---------------------------------------------------------------------------
  # handle_command/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_command(_state, %{type: "jobsite.audit.record", payload: payload}) do
    with {:ok, route} <- Aggregate.required_binary(Aggregate.get(payload, :route), :route),
         {:ok, method} <- Aggregate.required_binary(Aggregate.get(payload, :method), :method),
         {:ok, remote_address} <-
           Aggregate.required_binary(Aggregate.get(payload, :remote_address), :remote_address),
         {:ok, outcome} <- validate_outcome(Aggregate.get(payload, :outcome)),
         {:ok, error_code} <- validate_error_code(outcome, Aggregate.get(payload, :error_code)),
         {:ok, jobsite_id} <- validate_jobsite_id(Aggregate.get(payload, :jobsite_id)) do
      {:ok,
       %{
         stream_id: @stream_id,
         event_type: "JobsiteRequestAudited",
         payload: %{
           route: route,
           method: method,
           outcome: outcome,
           error_code: error_code,
           jobsite_id: jobsite_id,
           remote_address: remote_address,
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now())
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # Validation - each rejection is distinct (AGENTS.md §5.3)
  # ---------------------------------------------------------------------------

  defp validate_outcome(value) when value in @outcomes, do: {:ok, value}

  defp validate_outcome(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_outcome, value}}

  defp validate_outcome(_), do: {:error, {:missing_or_invalid, :outcome}}

  defp validate_error_code("rejected", value) when is_binary(value) and value != "",
    do: {:ok, value}

  defp validate_error_code("rejected", _), do: {:error, {:error_code_required, "rejected"}}
  defp validate_error_code("accepted", nil), do: {:ok, nil}

  defp validate_error_code("accepted", value) when is_binary(value) and value != "",
    do: {:ok, value}

  defp validate_error_code("accepted", _), do: {:error, {:missing_or_invalid, :error_code}}

  defp validate_jobsite_id(nil), do: {:ok, nil}
  defp validate_jobsite_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp validate_jobsite_id(_), do: {:error, {:missing_or_invalid, :jobsite_id}}
end
