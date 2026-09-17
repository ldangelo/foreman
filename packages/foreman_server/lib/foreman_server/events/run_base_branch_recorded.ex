defmodule ForemanServer.Events.RunBaseBranchRecorded do
  @moduledoc """
  Typed event emitted when the run's PR base branch is durably recorded.

  `RunExecutor.remember_run_base_branch/1` resolves the base branch once
  (the checkout's branch at the moment the first phase starts) and holds
  it in memory. Persisting it here means a resumed executor reads the
  ORIGINAL base branch back from the projection instead of re-deriving
  it from whatever branch the registered checkout happens to be on at
  resume time — the failure mode this event exists to close.
  """
  @enforce_keys [:run_id, :base_branch]
  @type t :: %__MODULE__{
          run_id: String.t(),
          base_branch: String.t(),
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :base_branch, :sequence]
end
