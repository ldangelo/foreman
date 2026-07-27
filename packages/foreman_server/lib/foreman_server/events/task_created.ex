defmodule ForemanServer.Events.TaskCreated do
  @enforce_keys [:task_id, :project_id]
  @type t :: %__MODULE__{
    task_id: String.t(),
    project_id: String.t(),
    title: String.t() | nil,
    description: String.t() | nil,
    priority: String.t() | nil,
    status: String.t() | nil,
    dependencies: [String.t()] | nil,
    task_type: String.t() | nil,
    source: String.t() | nil,
    external_id: String.t() | nil,
    external_link: String.t() | nil,
    dedupe_key: String.t() | nil,
    integration_event_type: String.t() | nil,
    planning_run_id: String.t() | nil,
    planning_kind: String.t() | nil,
    planning_phase_id: String.t() | nil,
    trace_event_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :task_id,
    :project_id,
    :title,
    :description,
    :priority,
    :status,
    :dependencies,
    :task_type,
    :source,
    :external_id,
    :external_link,
    :dedupe_key,
    :integration_event_type,
    :planning_run_id,
    :planning_kind,
    :planning_phase_id,
    :trace_event_id
  ]
end
