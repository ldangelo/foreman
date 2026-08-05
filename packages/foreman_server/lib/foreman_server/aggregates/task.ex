defmodule ForemanServer.Aggregates.Task do
  @moduledoc "Task aggregate: validates task lifecycle commands while preserving existing event names."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.{Aggregate, ProjectionStore}

  defmodule Annotation do
    @moduledoc "An annotation on a task with enforced schema from TaskAnnotated."
    @enforce_keys [:body, :author, :created_at]
    defstruct [:body, :author, :created_at, metadata: %{}]
  end

  defmodule State do
    @enforce_keys [:exists?]
    defstruct [
      :exists?,
      :task_id,
      :project_id,
      :status,
      :approval_id,
      :approved_by,
      :approved_at,
      :run_id,
      :workflow_snapshot,
      :failure_reason,
      :task_type,
      :title,
      :description,
      :priority,
      dependencies: [],
      annotations: []
    ]
  end
  @valid_statuses MapSet.new(["open", "ready", "in_progress", "blocked", "closed", "failed"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      task_id: nil,
      project_id: nil,
      status: nil,
      approval_id: nil,
      approved_by: nil,
      approved_at: nil,
      run_id: nil,
      workflow_snapshot: nil,
      failure_reason: nil,
      task_type: nil,
      title: nil,
      description: nil,
      priority: nil,
      dependencies: [],
      annotations: []
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "TaskCreated" ->
        %State{
          state
          | exists?: true,
            task_id: Aggregate.get(payload, :task_id),
            project_id: Aggregate.get(payload, :project_id),
            status: Aggregate.get(payload, :status, "open"),
            task_type: Aggregate.get(payload, :task_type),
            title: Aggregate.get(payload, :title),
            description: Aggregate.get(payload, :description),
            priority: Aggregate.get(payload, :priority),
            dependencies: Aggregate.get(payload, :dependencies, [])
        }

      "TaskUpdated" ->
        %State{
          state
          | exists?: true,
            task_id: Aggregate.get(payload, :task_id) || state.task_id,
            status: Aggregate.get(payload, :status, state.status),
            title: Aggregate.get(payload, :title) || state.title,
            description: Aggregate.get(payload, :description) || state.description,
            priority: Aggregate.get(payload, :priority) || state.priority
        }

      "TaskApproved" ->
        %State{
          state
          | exists?: true,
            status: "ready",
            approval_id: Aggregate.get(payload, :approval_id),
            approved_by: Aggregate.get(payload, :approved_by),
            approved_at: Aggregate.get(payload, :approved_at),
            run_id: Aggregate.get(payload, :run_id),
            workflow_snapshot: Aggregate.get(payload, :workflow_snapshot)
        }

      "TaskDispatched" ->
        %State{
          state
          | exists?: true,
            status: "in_progress",
            run_id: Aggregate.get(payload, :run_id) || state.run_id
        }

      "TaskExecutionCompleted" ->
        %State{state | exists?: true, status: "closed", failure_reason: nil}

      "TaskExecutionFailed" ->
        %State{
          state
          | exists?: true,
            status: "failed",
            failure_reason: Aggregate.get(payload, :reason)
        }

      "TaskAnnotated" ->
        annotation = %Annotation{
          body: Aggregate.get(payload, :body),
          author: Aggregate.get(payload, :author),
          created_at: Aggregate.get(payload, :created_at),
          metadata: Map.drop(payload, [:body, :author, :created_at])
        }

        %State{state | exists?: true, annotations: state.annotations ++ [annotation]}

      "TaskDependencyAdded" ->
        %State{
          state
          | exists?: true,
            dependencies:
              Enum.uniq((state.dependencies || []) ++ [Aggregate.get(payload, :depends_on)])
        }

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
  def handle_command(state, %{type: "task.approve", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- require_approvable(state),
         {:ok, approved_by} <- require_nonempty_string(Aggregate.get(payload, :approved_by), :approved_by),
         {:ok, approval_id} <- require_nonempty_string(Aggregate.get(payload, :approval_id), :approval_id),
         {:ok, run_id} <- require_nonempty_string(Aggregate.get(payload, :run_id), :run_id),
         {:ok, approved_at} <- require_nonempty_string(Aggregate.get(payload, :approved_at), :approved_at),
         :ok <- require_workflow_snapshot(Aggregate.get(payload, :workflow_snapshot)) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskApproved",
         payload: %{
           task_id: task_id,
           approval_id: approval_id,
           approved_by: approved_by,
           approved_at: approved_at,
           run_id: run_id,
           workflow_snapshot: Aggregate.get(payload, :workflow_snapshot)
         }
       }}
    end
  end



  def handle_command(state, %{type: command_type, payload: payload})
      when command_type in ["task.block", "task.close"] do
    status = %{"task.block" => "blocked", "task.close" => "closed"}[command_type]

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
         payload: %{
           task_id: task_id,
           body: body,
           author: Aggregate.get(payload, :author)
         }
       }}
    end
  end

  def handle_command(state, %{type: "task.dispatch", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- require_dispatchable(state) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskDispatched",
         payload: %{
           task_id: task_id,
           run_id: state.run_id,
           approval_id: state.approval_id
         }
       }}
    end
  end

  def handle_command(state, %{type: "task.execution_complete", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- require_executing(state) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskExecutionCompleted",
         payload: %{
           task_id: task_id,
           run_id: state.run_id
         }
       }}
    end
  end

  def handle_command(state, %{type: "task.execution_fail", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- require_exists(state, task_id),
         :ok <- require_executing(state) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskExecutionFailed",
         payload: %{
           task_id: task_id,
           run_id: state.run_id,
           reason: Aggregate.get(payload, :reason)
         }
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
      do: %State{state | status: status},
      else: state
  end

  defp require_absent(%State{exists?: true}, task_id),
    do: {:error, {:already_exists, :task, task_id}}

  defp require_absent(_state, _task_id), do: :ok

  defp require_exists(%State{exists?: true}, _task_id), do: :ok
  defp require_exists(_state, task_id), do: {:error, {:not_found, :task, task_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_task_status, status}}
  end


  defp require_approvable(%State{status: status}) when status in ["open", "blocked"], do: :ok
  defp require_approvable(%State{status: status}),
    do: {:error, {:task_not_approvable, status}}



  defp validate_status(status), do: {:error, {:invalid_task_status, status}}

  defp allow_transition(_state, nil), do: :ok

  # Dispatch requires a fully-approved task with a bound run and approval id.
  defp require_dispatchable(%State{
         status: "ready",
         run_id: run_id,
         approval_id: approval_id
       })
       when is_binary(run_id) and run_id != "" and is_binary(approval_id) and approval_id != "",
       do: :ok

  defp require_dispatchable(%State{status: status, run_id: run_id, approval_id: approval_id}),
    do: {:error, {:task_not_dispatchable, status, run_id, approval_id}}

  defp require_executing(%State{status: "in_progress"}), do: :ok
  defp require_executing(%State{status: status}), do: {:error, {:task_not_executing, status}}



  defp allow_transition(%State{status: status}, new_status)
       when status == "merged" and new_status != status,
       do: {:error, {:invalid_task_transition, status, new_status}}

  defp allow_transition(_state, _new_status), do: :ok

  defp reject_self_dependency(task_id, task_id), do: {:error, :self_dependency}
  defp reject_self_dependency(_task_id, _depends_on), do: :ok

  defp validate_project_allows_tasks(nil), do: {:error, :project_id_required}

  defp validate_project_allows_tasks(project_id) do
    case ProjectionStore.project(project_id) do
      %{status: "archived"} -> {:error, {:project_archived, project_id}}
      _ -> :ok
    end
  end
  defp require_nonempty_string(value, _key) when is_binary(value) and value != "",
    do: {:ok, value}
  defp require_nonempty_string(value, key),
    do: {:error, {:missing_or_invalid, key, value}}

  defp require_workflow_snapshot(snapshot) when is_map(snapshot) and map_size(snapshot) > 0,
    do: :ok
  defp require_workflow_snapshot(snapshot),
    do: {:error, {:missing_or_invalid, :workflow_snapshot, snapshot}}


end

