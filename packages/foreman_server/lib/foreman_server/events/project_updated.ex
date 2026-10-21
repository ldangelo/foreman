defmodule ForemanServer.Events.ProjectUpdated do
  @moduledoc """
  Typed event emitted when a project is updated.

  Settings (see `ForemanServer.Aggregates.Project.Settings`) travel as typed
  optional fields; a struct cannot tell "absent" from "clear", so cleared
  settings are listed by name in `cleared_settings`. Aggregate and projection
  fold both INTO `config` under the same names. No key is enforced beyond the
  original two, so historical events still decode.
  """
  @enforce_keys [:project_id, :task_provider]
  @type t :: %__MODULE__{
          project_id: String.t(),
          task_provider: map() | nil,
          config: map(),
          goal: String.t() | nil,
          instructions: String.t() | nil,
          thread_model: String.t() | nil,
          thread_effort: String.t() | nil,
          coordinator_provider: String.t() | nil,
          coordinator_model: String.t() | nil,
          coordinator_effort: String.t() | nil,
          max_concurrent_runs: pos_integer() | nil,
          daily_thread_cap: pos_integer() | nil,
          pr_auto_fix: map() | nil,
          cleared_settings: [String.t()]
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :task_provider,
    :goal,
    :instructions,
    :thread_model,
    :thread_effort,
    :coordinator_provider,
    :coordinator_model,
    :coordinator_effort,
    :max_concurrent_runs,
    :daily_thread_cap,
    :pr_auto_fix,
    config: %{},
    cleared_settings: []
  ]
end
