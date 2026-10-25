defmodule ForemanServer.Events.JobsiteSessionBound do
  @moduledoc """
  Typed event emitted while a jobsite iteration is still running, as soon as its agent run reports
  the provider session id it was given.

  `JobsiteIterationCompleted` carries the session id only once the iteration ENDS, so an executor
  that dies mid-iteration would leave the aggregate with no session, and a resume would send
  `Continue.` to a blank agent. Recording the id here is what lets `Jobsite.resume/1` continue the
  interrupted conversation (`ForemanServer.Aggregates.Jobsite` keeps the latest bound id).
  """
  @enforce_keys [:jobsite_id, :index, :session_id]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          index: pos_integer(),
          session_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :index, :session_id]
end
