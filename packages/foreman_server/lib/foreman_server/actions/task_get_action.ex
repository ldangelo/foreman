defmodule ForemanServer.Actions.TaskGetAction do
  @moduledoc """
  A `Jido.Action` that returns the current projection of a task by id
  (TRD-2026-4212be7e, JAF-T002).

  Delegates to `ForemanServer.ProjectionStore.task_projection/1`. The
  projection includes the task's status, priority, title, assignee,
  description, notes, design, labels, dependencies, and timestamps
  (whatever the projection currently holds).

  ## Output shape

      {:ok, %{task: %{id: "...", status: "in_progress", ...}}}

  Returns `{:error, :not_found}` when no task with the given id is in
  the projection store.

  ## Failure modes

    - `{:error, :not_found}` — no task with that id.
    - `{:error, {:projection_store_unreachable, reason}}` — the
      ProjectionStore GenServer is not running (unreachable).
  """

  use Jido.Action,
    name: "task_get",
    description: "Read the current projection of a task by id",
    category: "task",
    tags: ["task", "projection", "foreman"],
    vsn: "1.0.0",
    schema: [
      task_id: [
        type: :string,
        required: true,
        doc: "Foreman task id (foreman-XXX) to look up"
      ]
    ],
    output_schema: [
      task: [type: :map, required: true, doc: "Task projection map"]
    ]

  @impl true
  def run(params, _context) do
    task_id = Map.get(params, :task_id, "")

    if task_id == "" do
      {:error, :invalid_task_id}
    else
      try do
        case ForemanServer.ProjectionStore.task_projection(task_id) do
          nil ->
            {:error, :not_found}

          projection ->
            {:ok, %{task: projection}}
        end
      catch
        :exit, {:noproc, _} ->
          {:error, {:projection_store_unreachable, :noproc}}

        :exit, reason ->
          {:error, {:projection_store_unreachable, reason}}
      end
    end
  end
end
