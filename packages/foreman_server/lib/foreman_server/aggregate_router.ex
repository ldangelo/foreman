defmodule ForemanServer.AggregateRouter do
  @moduledoc "Routes command families to event-sourced aggregate validators."

  alias ForemanServer.Aggregate

  alias ForemanServer.Aggregates.{
    InboxThread,
    Integration,
    Phase,
    Project,
    Recovery,
    Run,
    Scheduler,
    Task,
    VcsOperation,
    Worker
  }

  @spec route(String.t(), map()) :: {:ok, map()} | {:error, term()} | :unhandled
  def route(command_type, payload) when is_binary(command_type) and is_map(payload) do
    case command_type do
      "project." <> _ -> route_project(command_type, payload)
      "task.create" -> route_task_create(command_type, payload)
      "task." <> _ -> route_task(command_type, payload)
      "run." <> _ -> route_run(command_type, payload)
      "phase." <> _ -> route_phase(command_type, payload)
      "inbox." <> _ -> route_inbox(command_type, payload)
      "worker." <> _ -> route_worker(command_type, payload)
      "scheduler." <> _ -> route_scheduler(command_type, payload)
      "vcs." <> _ -> route_vcs(command_type, payload)
      "recovery." <> _ -> route_recovery(command_type, payload)
      "integration." <> _ -> route_integration(command_type, payload)
      _ -> :unhandled
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
      Aggregate.decide(Phase, "phase:#{stream_part(run_id)}:#{stream_part(phase_id)}", command_type, payload)
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
      Aggregate.decide(Worker, "worker:#{stream_part(run_id)}:#{stream_part(worker_id)}", command_type, payload)
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
      Aggregate.decide(Integration, "integration:#{stream_part(dedupe_key)}", command_type, payload)
    end
  end

  defp stream_part(value) when is_binary(value), do: String.replace(value, ":", "%3A")
  defp stream_part(value), do: value
end
