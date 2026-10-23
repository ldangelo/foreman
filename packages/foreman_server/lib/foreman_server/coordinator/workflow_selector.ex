defmodule ForemanServer.Coordinator.WorkflowSelector do
  @moduledoc """
  Chooses the workflow of a thread the coordinator starts. Nothing else selects
  a workflow from free text (`Catalog.type_to_workflow/1` maps only a beads
  `issue_type`), so the choice is explicit and deterministic:

    1. an explicit `workflow` must be an installed workflow, else
       `{:error, {:invalid_workflow, name, reason}}` when a manifest of that name
       is installed but was refused (the operator needs the validation error, not
       "unknown"), else `{:error, {:unknown_workflow, name, valid_names}}` so the
       next turn can correct itself;
    2. a `task_type` mapped through `Catalog.type_to_workflow/1`;
    3. otherwise `{:error, :no_workflow}`: the coordinator asks the operator
       instead of guessing.

  There is no project-level default-workflow setting in E1, so no step uses one.
  A hallucinated workflow name can never reach `task.create`, and neither can the
  name of a workflow whose manifest failed validation.
  """

  alias ForemanServer.Workflow.Catalog

  @type invalid :: %{name: String.t(), reason: String.t()}
  @type error ::
          {:unknown_workflow, String.t(), [String.t()]}
          | {:invalid_workflow, String.t(), String.t()}
          | :no_workflow

  @spec select(map(), [String.t()], [invalid()]) :: {:ok, String.t()} | {:error, error()}
  def select(params, installed, invalid)
      when is_map(params) and is_list(installed) and is_list(invalid) do
    case params do
      %{"workflow" => name} ->
        select_named(name, installed, invalid)

      %{"task_type" => type} ->
        case Catalog.type_to_workflow(type) do
          {:ok, name} -> {:ok, name}
          {:error, :unmapped_type} -> {:error, :no_workflow}
        end

      _ ->
        {:error, :no_workflow}
    end
  end

  defp select_named(name, installed, invalid) do
    cond do
      name in installed ->
        {:ok, name}

      refusal = Enum.find(invalid, &(&1.name == name)) ->
        {:error, {:invalid_workflow, name, refusal.reason}}

      true ->
        {:error, {:unknown_workflow, name, Enum.sort(installed)}}
    end
  end
end
