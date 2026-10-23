defmodule ForemanServer.Threads.Steerer do
  @moduledoc """
  Steering capability of a thread's agent provider.

  The thread DTO's `steering` is the mode every thread is GUARANTEED: `"pause_resume"`
  (pause, commit partial work, resume with the operator message as the next prompt;
  `ForemanServer.Jobsite.steer/3` for the jobsite door, `run.steer` for the workflow door).

  Live mid-phase steering (docs/plans/live-steering.md, beads foreman-s48kc/b3jtt) is an
  ATTEMPT made first by the workflow door when the running phase's provider supports
  streaming input (`ForemanServer.Workflow.LiveSteer`: claude, pi): the message is written
  into the running session and the run is not paused. It is not a thread-level capability:
  it depends on the phase running at that moment, so its outcome is reported per message
  by the `RunSteerDelivered` / `RunSteerConsumed` / `RunSteerUndelivered` events (the
  transcript shows them), and any refusal falls back to `"pause_resume"`. Do not return
  `"live"` from `capability/1`: it would promise what only the delivery events can state.
  """

  @type capability :: String.t()

  @doc "The guaranteed steering mode of a thread: always `\"pause_resume\"` (see the moduledoc)."
  @spec capability(atom() | String.t() | nil) :: capability()
  def capability(_provider), do: "pause_resume"
end
