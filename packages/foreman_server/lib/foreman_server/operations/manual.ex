defmodule ForemanServer.Operations.Manual do
  @moduledoc "Operator-initiated run manipulation routed through CommandRouter."

  alias ForemanServer.CommandRouter

  @doc """
  Marks a run as recovered by dispatching a `run.recover` command with
  `outcome: "recovered"` through the CommandRouter. This appends a
  `RunRecoveryEvent` to the run stream and updates projections — it does NOT
  directly mutate the read model.
  """
  @spec mark_recovered(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_recovered(run_id) when is_binary(run_id) do
    CommandRouter.handle(%{
      command_id: "ops:manual:run.recover:#{run_id}:#{System.unique_integer([:positive])}",
      command_type: "run.recover",
      payload: %{
        run_id: run_id,
        outcome: "recovered"
      }
    })
  end

  @doc """
  Forces a run to complete by dispatching a `run.complete` command through
  the CommandRouter. If the run is already terminal, `RunAlreadyCompleted`
  is appended idempotently. The appropriate completion event is determined
  by the Run aggregate.
  """
  @spec force_complete(String.t()) :: {:ok, map()} | {:error, term()}
  def force_complete(run_id) when is_binary(run_id) do
    CommandRouter.handle(%{
      command_id: "ops:manual:run.complete:#{run_id}:#{System.unique_integer([:positive])}",
      command_type: "run.complete",
      payload: %{
        run_id: run_id
      }
    })
  end
end
