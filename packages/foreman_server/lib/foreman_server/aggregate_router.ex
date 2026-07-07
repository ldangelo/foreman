defmodule ForemanServer.AggregateRouter do
  @moduledoc "Routes command families to event-sourced aggregate validators."

  alias ForemanServer.Aggregate

  alias ForemanServer.Aggregates.{
    ArtifactReport,
    Attachment,
    ExternalTrigger,
    ImportMigration,
    InboxThread,
    Integration,
    OperatorIntervention,
    Phase,
    PlanningFlow,
    Project,
    Recovery,
    Run,
    Scheduler,
    Task,
    ToolCall,
    VcsOperation,
    Worker
  }

  @spec route(String.t(), map()) :: {:ok, map()} | {:error, term()} | :unhandled
  def route(command_type, payload) when is_binary(command_type) and is_map(payload) do
    case command_type do
      "project." <> _ ->
        route_project(command_type, payload)

      "task.create" ->
        route_task_create(command_type, payload)

      "task." <> _ ->
        route_task(command_type, payload)

      "run." <> _ ->
        route_run(command_type, payload)

      type when type in ["phase.report.produce", "phase.verdict"] ->
        route_artifact_report(command_type, payload)

      "phase." <> _ ->
        route_phase(command_type, payload)

      "inbox." <> _ ->
        route_inbox(command_type, payload)

      "worker." <> _ ->
        route_worker(command_type, payload)

      "scheduler." <> _ ->
        route_scheduler(command_type, payload)

      "vcs." <> _ ->
        route_vcs(command_type, payload)

      "recovery." <> _ ->
        route_recovery(command_type, payload)

      "integration." <> _ ->
        route_integration(command_type, payload)

      type when type in ["PlanningFlowCommand", "plan.prd", "plan.trd"] ->
        route_planning(command_type, payload)

      "planning." <> _ ->
        route_planning(command_type, payload)

      "tool." <> _ ->
        route_tool_call(command_type, payload)

      "operator." <> _ ->
        route_operator(command_type, payload)

      "migration." <> _ ->
        route_migration(command_type, payload)

      "external." <> _ ->
        route_external(command_type, payload)

      "attach." <> _ ->
        route_attachment(command_type, payload)

      _ ->
        :unhandled
    end
  end

  def route(_command_type, _payload), do: :unhandled

  defp route_project(command_type, payload) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id) do
      Aggregate.decide(Project, "project:#{project_id}", command_type, payload)
    end
  end

  defp route_task_create(command_type, payload) do
    case Aggregate.get(payload, :task_id) || Aggregate.get(payload, :id) do
      task_id when is_binary(task_id) and task_id != "" ->
        Aggregate.decide(Task, "task:#{task_id}", command_type, payload)

      _ ->
        :unhandled
    end
  end

  defp route_task(command_type, payload)
       when command_type in ["task.approve", "task.block", "task.close"] do
    case Aggregate.get(payload, :task_id) do
      task_id when is_binary(task_id) and task_id != "" ->
        Aggregate.decide(Task, "task:#{task_id}", command_type, payload)

      _ ->
        :unhandled
    end
  end

  defp route_task(command_type, payload) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id) do
      Aggregate.decide(Task, "task:#{task_id}", command_type, payload)
    end
  end

  defp route_run(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      Aggregate.decide(Run, "run:#{run_id}", command_type, payload)
    end
  end

  defp route_phase(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id) do
      Aggregate.decide(
        Phase,
        "phase:#{stream_part(run_id)}:#{stream_part(phase_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_inbox(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      Aggregate.decide(InboxThread, "inbox:#{run_id}", command_type, payload)
    end
  end

  defp route_worker(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, worker_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :worker_id), :worker_id) do
      Aggregate.decide(
        Worker,
        "worker:#{stream_part(run_id)}:#{stream_part(worker_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_scheduler(command_type, payload) do
    project_id = Aggregate.get(payload, :project_id, "global")
    Aggregate.decide(Scheduler, "scheduler:#{stream_part(project_id)}", command_type, payload)
  end

  defp route_vcs(command_type, payload) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id) do
      Aggregate.decide(VcsOperation, "vcs:#{operation_id}", command_type, payload)
    end
  end

  defp route_recovery(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      Aggregate.decide(Recovery, "recovery:#{run_id}", command_type, payload)
    end
  end

  defp route_integration(command_type, payload) do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key) do
      Aggregate.decide(
        Integration,
        "integration:#{stream_part(dedupe_key)}",
        command_type,
        payload
      )
    end
  end

  defp route_planning(command_type, payload) do
    with {:ok, flow_id} <- planning_flow_id(payload) do
      Aggregate.decide(PlanningFlow, "planning:#{stream_part(flow_id)}", command_type, payload)
    end
  end

  defp route_tool_call(command_type, payload) do
    with {:ok, tool_call_id} <- tool_call_id(payload) do
      Aggregate.decide(ToolCall, tool_call_stream(payload, tool_call_id), command_type, payload)
    end
  end

  defp route_operator(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      Aggregate.decide(
        OperatorIntervention,
        "operator:#{stream_part(run_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_migration(command_type, payload) do
    with {:ok, import_id} <- import_id(payload) do
      Aggregate.decide(
        ImportMigration,
        "migration:#{stream_part(import_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_external(command_type, payload) do
    with {:ok, trigger_id} <- external_trigger_id(payload) do
      Aggregate.decide(
        ExternalTrigger,
        "external:#{stream_part(trigger_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_artifact_report(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id) do
      Aggregate.decide(
        ArtifactReport,
        "artifact_report:#{stream_part(run_id)}:#{stream_part(phase_id)}",
        command_type,
        payload
      )
    end
  end

  defp route_attachment(command_type, payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      worker_id = Aggregate.get(payload, :worker_id, "default") || "default"

      Aggregate.decide(
        Attachment,
        "attach:#{stream_part(run_id)}:#{stream_part(worker_id)}",
        command_type,
        payload
      )
    end
  end

  defp planning_flow_id(payload) do
    payload
    |> first_present([:flow_id, :run_id, :planning_run_id, :command_id])
    |> Aggregate.required_binary(:flow_id)
  end

  defp tool_call_id(payload) do
    payload
    |> first_present([:tool_call_id, :tool_call, :call_id, :id])
    |> Aggregate.required_binary(:tool_call_id)
  end

  defp tool_call_stream(payload, tool_call_id) do
    case Aggregate.get(payload, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        "tool_call:#{stream_part(run_id)}:#{stream_part(tool_call_id)}"

      _ ->
        "tool_call:#{stream_part(tool_call_id)}"
    end
  end

  defp import_id(payload) do
    payload
    |> first_present([:import_id, :migration_id])
    |> Aggregate.required_binary(:import_id)
  end

  defp external_trigger_id(payload) do
    payload
    |> first_present([:trigger_id, :command_id, :dedupe_key, :event_id, :external_id])
    |> Aggregate.required_binary(:trigger_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp stream_part(value) when is_binary(value), do: String.replace(value, ":", "%3A")
  defp stream_part(value), do: value
end
