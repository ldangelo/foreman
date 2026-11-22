defmodule ForemanServer.Overwatch.StopReport do
  @moduledoc """
  Typed result of `ForemanServer.Overwatch.WorkerSupervisor.stop_run_workers/1`.

  A worker that refuses to die must be visible, not folded into a plausible
  success, so the report separates the workers that are gone from the workers
  still running. `unstopped` is empty only when nothing of this run is left
  running; anything else names pids an operator has to look at.
  """

  @enforce_keys [:run_id, :stopped, :unstopped]
  defstruct [:run_id, :stopped, :unstopped]

  @type t :: %__MODULE__{
          run_id: String.t(),
          stopped: [pid()],
          unstopped: [pid()]
        }
end
