defmodule ForemanServer.TestSupport.BlockingAggregate do
  @moduledoc """
  Test-only aggregate that parks `handle_command/2` in a selective receive waiting
  for `{:release, ref}`. Used to demonstrate actor mailbox serialization,
  in-flight event loss on crash, and conflict detection with external appends.

  This aggregate is ONLY exercised by the serialization and in-flight event tests.
  All five domain aggregates (Project, Task, Run, Worker, Phase) use normal commands.

  ## Protocol

  1. `handle_command` parks waiting for `{:release, ref}`.
  2. Caller sends `{:release, ref}` to unblock.
  3. Actor returns `{:ok, event_spec}` and sends append request.
  4. After append confirmed, Actor calls `apply_event(state, event_spec)` with the
     event spec map.
  """

  use ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.TestSupport.BlockCommand

  defstruct [:aggregate_id, :aggregate_type, :status]

  @impl true
  def initial_state, do: %__MODULE__{}

  @impl true
  def handle_command(%__MODULE__{} = _state, %BlockCommand{} = cmd) do
    if pid = cmd.notify_pid, do: send(pid, {:block_entered, cmd.ref, self()})

    receive do
      {:release, ref} when ref == cmd.ref ->
        event_spec = %{
          stream_id: cmd.aggregate_id,
          event_type: "BlockEvent",
          payload: %{
            aggregate_id: cmd.aggregate_id,
            aggregate_type: cmd.aggregate_type
          }
        }

        {:ok, event_spec}
    after
      60_000 ->
        {:error, :timeout}
    end
  end

  def handle_command(_state, _cmd), do: {:error, :unhandled}

  @impl true
  # event_spec is the map returned by handle_command: %{event_type: ..., payload: ...}
  def apply_event(state, event_spec) when is_map(event_spec) do
    payload = Aggregate.event_payload(event_spec)
    %{
      state
      | aggregate_id: payload.aggregate_id,
        aggregate_type: payload.aggregate_type,
        status: :blocked
    }
  end
end
