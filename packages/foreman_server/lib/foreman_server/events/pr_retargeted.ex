defmodule ForemanServer.Events.PrRetargeted do
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :branch_name, :old_base_branch, :new_base_branch, :head_sha]
  @type t :: %__MODULE__{
    run_id: String.t(),
    project_id: String.t(),
    task_id: String.t(),
    pr_url: String.t(),
    branch_name: String.t(),
    old_base_branch: String.t(),
    new_base_branch: String.t(),
    head_sha: String.t()
  }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :task_id, :pr_url, :branch_name, :old_base_branch, :new_base_branch, :head_sha]
end
