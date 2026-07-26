defmodule ForemanServer.TestSupport.BlockingAggregate do
  @moduledoc """
  Test-only aggregate that parks execute/2 in a selective receive waiting for {:release, ref}.
  Used to demonstrate Commanded's mailbox serialization, in-flight event loss on crash,
  and conflict detection with external appends.

  This aggregate is ONLY exercised by the serialization and in-flight event tests.
  All five domain aggregates (Project, Task, Run, Worker, Phase) use normal commands.
  """

  alias ForemanServer.TestSupport.{BlockCommand, BlockEvent}

  defstruct [:aggregate_id, :aggregate_type, :status]

  def initial_state, do: %__MODULE__{}

  # Unblocked execution path: accepts BlockCommand, parks in receive
  def execute(%__MODULE_{} = state, %BlockCommand{} = cmd) do
    if pid = cmd.notify_pid, do: send(pid, {:block_entered, cmd.ref, self()})

    receive do
      {:release, ref} when ref == cmd.ref ->
        %BlockEvent{aggregate_id: cmd.aggregate_id, aggregate_type: cmd.aggregate_type}
    after
      60_000 ->
        :timeout
    end
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %BlockEvent{} = event) do
    %{
      state
      | aggregate_id: event.aggregate_id,
        aggregate_type: event.aggregate_type,
        status: :blocked
    }
  end
end
