defmodule ForemanServer.Aggregates.ExternalTrigger do
  @moduledoc "External trigger aggregate: dedupes external commands and accepted observations."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :accepted?, :observed?, :trigger_id]
    defstruct [:exists?, :accepted?, :observed?, :trigger_id]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      accepted?: false,
      observed?: false,
      trigger_id: nil
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ExternalTriggerCommand" ->
        %State{state | exists?: true, trigger_id: Aggregate.get(payload, :trigger_id)}

      "CommandAccepted" ->
        %State{state | accepted?: true, trigger_id: Aggregate.get(payload, :trigger_id)}

      "ExternalWorkerObserved" ->
        %State{state | observed?: true, trigger_id: Aggregate.get(payload, :trigger_id)}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "external.trigger", payload: payload}) do
    with {:ok, trigger_id} <- trigger_id(payload),
         :ok <- require_absent(state) do
      {:ok,
       %ForemanServer.Events.ExternalTriggerCommand{
         trigger_id: trigger_id
       }}
    end
  end

  def handle_command(state, %{type: "external.accept", payload: payload}) do
    with {:ok, trigger_id} <- trigger_id(payload),
         :ok <- require_existing(state),
         :ok <- reject_accepted(state) do
      {:ok,
       %ForemanServer.Events.CommandAccepted{
         trigger_id: trigger_id
       }}
    end
  end

  def handle_command(state, %{type: "external.worker.observe", payload: payload}) do
    with {:ok, trigger_id} <- trigger_id(payload),
         :ok <- require_existing(state) do
      {:ok,
       %ForemanServer.Events.ExternalWorkerObserved{
         trigger_id: trigger_id
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp trigger_id(payload) do
    payload
    |> first_present(["trigger_id", :command_id, :dedupe_key, :event_id, :external_id])
    |> Aggregate.required_binary(:trigger_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp require_absent(%State{exists?: true}), do: {:error, :external_trigger_already_recorded}
  defp require_absent(_state), do: :ok

  defp require_existing(%State{exists?: true}), do: :ok
  defp require_existing(_state), do: {:error, :external_trigger_not_recorded}

  defp reject_accepted(%State{accepted?: true}), do: {:error, :external_trigger_already_accepted}
  defp reject_accepted(_state), do: :ok

  defp escape(value), do: String.replace(value, ":", "%3A")
end
