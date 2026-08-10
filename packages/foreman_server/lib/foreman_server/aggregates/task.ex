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
      :acknowledged_run_id,
      :run_terminal_reason,
      :run_terminal_at,
      dependencies: [],
      annotations: [],
      retry_history: []
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
      acknowledged_run_id: nil,
      run_terminal_reason: nil,
      run_terminal_at: nil,
      dependencies: [],
      annotations: [],
      retry_history: []
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

      "TaskRunTerminated" ->
        apply_task_run_terminated(state, payload)

      "TaskRetried" ->
        apply_task_retried(state, payload)

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
         {:ok, approved_by} <-
           require_nonempty_string(Aggregate.get(payload, :approved_by), :approved_by),
         {:ok, approval_id} <-
           require_nonempty_string(Aggregate.get(payload, :approval_id), :approval_id),
         {:ok, run_id} <- require_nonempty_string(Aggregate.get(payload, :run_id), :run_id),
         {:ok, approved_at} <-
           require_nonempty_string(Aggregate.get(payload, :approved_at), :approved_at),
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

  def handle_command(state, %{type: "task.run_terminated", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, task_id),
         :ok <- require_in_progress(state),
         :ok <- require_run_matches_bound(state, run_id) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskRunTerminated",
         payload: %{
           task_id: task_id,
           run_id: run_id,
           reason: Aggregate.get(payload, :reason),
           acknowledged_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }
       }}
    end
  end

  def handle_command(state, %{type: "task.retry", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         {:ok, ack_id} <-
           Aggregate.required_binary(
             Aggregate.get(payload, :acknowledged_run_id),
             :acknowledged_run_id
           ),
         :ok <- require_exists(state, task_id),
         :ok <- require_run_matches_bound(state, ack_id),
         :ok <- require_in_progress(state) do
      {:ok,
       %{
         stream_id: "task:#{task_id}",
         event_type: "TaskRetried",
         payload: %{
           task_id: task_id,
           previous_run_id: state.run_id,
           reason: Aggregate.get(payload, :reason),
           retried_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp maybe_apply_terminal_run(state, payload, status) do
    if Aggregate.get(payload, :task_id) == Map.get(state, :task_id),
      do: %State{state | status: status},
      else: state
  end

  # `task.run_terminated` (and thus the subscription it triggers) MUST
  # only commit when the run it names is the run this task is currently
  # bound to. Mismatched run_ids are silently rejected — they signal a
  # stale subscriber re-fire, not a new remediation event. The aggregate
  # NEVER transitions status here: the design intent is a two-step gate
  # (acknowledge, then retry). `TaskRetried` is the only event that
  # resets status back to `open`.
  defp apply_task_run_terminated(state, payload) do
    event_run_id = Aggregate.get(payload, :run_id)

    cond do
      not is_binary(event_run_id) or event_run_id == "" ->
        state

      event_run_id != state.run_id ->
        state

      true ->
        %State{
          state
          | exists?: true,
            acknowledged_run_id: event_run_id,
            run_terminal_reason: Aggregate.get(payload, :reason),
            run_terminal_at: Aggregate.get(payload, :acknowledged_at)
        }
    end
  end

  # `task.retry` is the unconditional reset. The precondition guard at
  # handle-command time guarantees `state.run_id == state.acknowledged_run_id`,
  # so we trust the payload and clear every run-bound field the same way
  # `Approval.prepare/1` rebuilds them — and append to retry_history so the
  # operator path leaves a forensic trail.
  defp apply_task_retried(state, payload) do
    previous_run_id = state.run_id
    retried_at = Aggregate.get(payload, :retried_at)
    reason = Aggregate.get(payload, :reason)

    history_entry = %{
      run_id: previous_run_id,
      reason: reason,
      retried_at: retried_at
    }

    %State{
      state
      | exists?: true,
        status: "open",
        approval_id: nil,
        approved_by: nil,
        approved_at: nil,
        run_id: nil,
        workflow_snapshot: nil,
        acknowledged_run_id: nil,
        run_terminal_reason: nil,
        run_terminal_at: nil,
        retry_history: state.retry_history ++ [history_entry]
    }
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

  # `task.run_terminated` MUST only fire while the run it names is the run
  # the task is currently bound to — otherwise a stale subscriber would
  # rewrite the acknowledgement against a previous run.
  defp require_in_progress(%State{status: "in_progress"}), do: :ok
  defp require_in_progress(%State{status: status}), do: {:error, {:task_not_in_progress, status}}

  defp require_run_matches_bound(%State{run_id: run_id}, run_id)
       when is_binary(run_id) and run_id != "",
       do: :ok

  defp require_run_matches_bound(%State{run_id: bound}, run_id),
    do: {:error, {:run_id_mismatch, bound, run_id}}

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
