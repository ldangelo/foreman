defmodule ForemanServer.Events.ProjectThreadStarted do
  @moduledoc """
  Typed event emitted when a non-run thread (today: a jobsite) is counted
  against the project's daily thread cap. Workflow runs are counted by
  `ProjectRunReserved.reserved_on` instead. `day` is the UTC date
  (`Date.to_iso8601/1`) the thread started, fixed at command time so replay is
  deterministic.
  """
  @enforce_keys [:project_id, :thread_kind, :thread_id, :day]
  @type t :: %__MODULE__{
          project_id: String.t(),
          thread_kind: String.t(),
          thread_id: String.t(),
          day: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :thread_kind, :thread_id, :day]
end
