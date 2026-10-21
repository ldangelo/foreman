defmodule ForemanServer.Events.ScheduleCreated do
  @moduledoc """
  A scheduled task was defined for a project. `spec` is the normalised map from
  `ForemanServer.Schedule.Spec.to_map/1` (string keys, string values), never a
  struct, so the event is JSON-stable. The `prompt` is operator-authored data and
  is visible in the event log.
  """
  @enforce_keys [:schedule_id, :project_id, :name, :spec, :prompt, :workflow, :created_at]
  @type t :: %__MODULE__{
          schedule_id: String.t(),
          project_id: String.t(),
          name: String.t(),
          spec: %{String.t() => String.t()},
          prompt: String.t(),
          workflow: String.t(),
          auto_approve: boolean() | nil,
          overlap: String.t() | nil,
          misfire_grace_seconds: non_neg_integer() | nil,
          created_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :schedule_id,
    :project_id,
    :name,
    :spec,
    :prompt,
    :workflow,
    :auto_approve,
    :overlap,
    :misfire_grace_seconds,
    :created_at
  ]
end
