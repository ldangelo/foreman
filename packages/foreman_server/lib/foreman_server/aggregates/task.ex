defmodule ForemanServer.Aggregates.Task do
  @moduledoc "Task aggregate: validates task lifecycle commands while preserving existing event names."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.{Aggregate, ProjectionStore}

  @valid_statuses MapSet.new([
                    "open",
                    "backlog",
                    "ready",
                    "approved",
                    "in_progress",
                    "in-progress",
                    "review",
                    "merged",
                    "closed",
                    "conflict",
                    "failed",
                    "stuck",
                    "blocked",
                    "cooldown"
                  ])
  @impl true
  def initial_state, do: %{exists?: false, dependencies: [], annotations: []}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "TaskCreated" ->
        state
        |> Map.merge(payload)
        |> Map.put(:task_id, Aggregate.get(payload, :task_id))
        |> Map.put(:status, Aggregate.get(payload, :status, "open"))
        |> Map.put(:dependencies, Aggregate.get(payload, :dependencies, []))
        |> Map.put(:annotations, Map.get(state, :annotations, []))
        |> Map.put(:exists?, true)

      "TaskUpdated" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)

      "TaskAnnotated" ->
        annotation = %{
          body: Aggregate.get(payload, :body),
          author: Aggregate.get(payload, :author),
          created_at: Aggregate.get(payload, :created_at)
        }

        state
        |> Map.update(:annotations, [annotation], &(&1 ++ [annotation]))
        |> Map.put(:exists?, true)

      "TaskDependencyAdded" ->
        state
        |> Map.update(:dependencies, [Aggregate.get(payload, :depends_on)], fn deps ->
          Enum.uniq((deps || []) ++ [Aggregate.get(payload, :depends_on)])
        end)
        |> Map.put(:exists?, true)

      "RunCompleted" ->
        maybe_apply_terminal_run(state, payload, "closed")

      "RunFailed" ->
        maybe_apply_terminal_run(state, payload, "failed")

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "task.create", payload: payload}) do
    task_id = Aggregate.get(payload, :task_id) || Aggregate.get(payload, :id)

    with {:ok, task_id} <- Aggregate.required_binary(task_id, :task_id),
         :ok <- require_absent(state, task_id),
         :ok <- validate_status(Aggregate.get(payload, :status, "open")),
         :ok <- validate_project_allows_tasks(Aggregate.get(payload, :project_id)) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskCreated",
         payload: %{
           task_id: task_id,
           project_id: Aggregate.get(payload, :project_id),
           title: Aggregate.get(payload, :title, task_id),
           description: Aggregate.get(payload, :description),
           priority: Aggregate.get(payload, :priority),
           status: Aggregate.get(payload, :status, "open"),
           dependencies: Aggregate.get(payload, :dependencies, []),
           task_type: Aggregate.get(payload, :task_type) || Aggregate.get(payload, :type),
           source: Aggregate.get(payload, :source),
           external_id: Aggregate.get(payload, :external_id),
           external_link: Aggregate.get(payload, :external_link),
           dedupe_key: Aggregate.get(payload, :dedupe_key),
           integration_event_type: Aggregate.get(payload, :integration_event_type),
           planning_run_id: Aggregate.get(payload, :planning_run_id),
           planning_kind: Aggregate.get(payload, :planning_kind),
           planning_phase_id: Aggregate.get(payload, :planning_phase_id),
           trace_event_id: Aggregate.get(payload, :trace_event_id)
         }
       }}
    end
  end

  def handle_command(state, %{type: command_type, payload: payload})
      when command_type in ["task.approve", "task.block", "task.close"] do
    status =
      %{"task.approve" => "ready", "task.block" => "blocked", "task.close" => "closed"}[
        command_type
      ]

    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- allow_transition(state, status) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskUpdated",
         payload: %{task_id: task_id, status: status}
       }}
    end
  end

  def handle_command(state, %{type: "task.update", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- validate_status(Aggregate.get(payload, :status)),
         :ok <- allow_transition(state, Aggregate.get(payload, :status)) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskUpdated",
         payload: Map.put(payload, :task_id, task_id)
       }}
    end
  end

  def handle_command(state, %{type: "task.annotate", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         {:ok, body} <- Aggregate.required_binary(Aggregate.get(payload, :body), :body) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskAnnotated",
         payload: %{task_id: task_id, body: body, author: Aggregate.get(payload, :author)}
       }}
    end
  end

  def handle_command(state, %{type: "task.add_dependency", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         {:ok, depends_on} <-
           Aggregate.required_binary(Aggregate.get(payload, :depends_on), :depends_on),
         :ok <- require_exists(state, task_id),
         :ok <- reject_self_dependency(task_id, depends_on) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskDependencyAdded",
         payload: %{task_id: task_id, depends_on: depends_on}
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp maybe_apply_terminal_run(state, payload, status) do
    if Aggregate.get(payload, :task_id) == Map.get(state, :task_id),
      do: Map.put(state, :status, status),
      else: state
  end

  defp require_absent(%{exists?: true}, task_id), do: {:error, {:already_exists, :task, task_id}}
  defp require_absent(_state, _task_id), do: :ok

  defp require_exists(%{exists?: true}, _task_id), do: :ok
  defp require_exists(_state, task_id), do: {:error, {:not_found, :task, task_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_task_status, status}}
  end

  defp validate_status(status), do: {:error, {:invalid_task_status, status}}

  defp allow_transition(_state, nil), do: :ok

  defp allow_transition(%{status: status}, new_status)
       when status in ["closed", "merged"] and new_status != status,
       do: {:error, {:invalid_task_transition, status, new_status}}

  defp allow_transition(_state, _new_status), do: :ok

  defp reject_self_dependency(task_id, task_id), do: {:error, :self_dependency}
  defp reject_self_dependency(_task_id, _depends_on), do: :ok

  defp validate_project_allows_tasks(nil), do: :ok

  defp validate_project_allows_tasks(project_id) do
    case ProjectionStore.project(project_id) do
      %{status: "archived"} -> {:error, {:project_archived, project_id}}
      _ -> :ok
    end
  end
end
