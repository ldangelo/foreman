defmodule ForemanServer.Events.PrReset do
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :branch_name, :action, :reason]
  @type t :: %__MODULE__{
    run_id: String.t(),
    project_id: String.t(),
    task_id: String.t(),
    pr_url: String.t(),
    branch_name: String.t(),
    action: String.t(),
    reason: String.t()
  }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :task_id, :pr_url, :branch_name, :action, :reason]
end
