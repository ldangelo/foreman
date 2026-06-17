defmodule ForemanServer.WorkerLauncher do
  @moduledoc "Launches the Node/Pi worker bridge for scheduler-claimed tasks."

  alias ForemanServer.EventStore

  @spec launch(map(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def launch(task, run_id, phases) when is_map(task) and is_binary(run_id) do
    task_id = Map.fetch!(task, :task_id)

    with {:ok, project_path} <- project_path(task),
         {:ok, foreman} <- foreman_executable() do
      workflow = workflow_name(task)
      args = ["run", "task", task_id, workflow, "--project-path", project_path, "--no-watch", "--run-id", run_id]

      {:ok, pid} =
        Task.start(fn ->
          append("WorkerLaunchRequested", task, run_id, %{
            workflow: workflow,
            phases: phases,
            command: Enum.join([foreman | args], " ")
          })

          {output, status} =
            System.cmd(foreman, args,
              cd: project_path,
              stderr_to_stdout: true,
              env: worker_env()
            )

          if status == 0 do
            append("WorkerLaunchCompleted", task, run_id, %{workflow: workflow, output: output})
          else
            append("WorkerLaunchFailed", task, run_id, %{workflow: workflow, exit_code: status, output: output})
            append_task_failed(task, run_id, output)
          end
        end)

      {:ok, %{pid: pid, workflow: workflow}}
    end
  end

  defp project_path(task) do
    project_id = Map.get(task, :project_id)

    cond do
      is_binary(Map.get(task, :project_path)) ->
        {:ok, Map.get(task, :project_path)}

      is_binary(project_id) ->
        case ForemanServer.ProjectionStore.project(project_id) do
          %{path: path} when is_binary(path) -> {:ok, path}
          _ -> {:error, {:missing_project_path, project_id}}
        end

      true ->
        {:error, :missing_project_id}
    end
  end

  defp foreman_executable do
    case System.find_executable("foreman") do
      nil -> {:error, :foreman_executable_not_found}
      path -> {:ok, path}
    end
  end

  defp worker_env do
    env = [{"FOREMAN_BACKEND", "node"}]

    case database_url() do
      nil -> env
      url -> [{"DATABASE_URL", url} | env]
    end
  end

  defp database_url do
    System.get_env("DATABASE_URL") || database_url_from_file()
  end

  defp database_url_from_file do
    [Path.expand("../../.env", File.cwd!()), Path.expand(".env", File.cwd!())]
    |> Enum.find_value(fn path ->
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            ["DATABASE_URL", value] -> String.trim(value)
            _ -> nil
          end
        end)
      end
    end)
  end

  defp workflow_name(task) do
    Map.get(task, :workflow) || Map.get(task, :task_type) || Map.get(task, :type) || "feature"
  end

  defp append(event_type, task, run_id, payload) do
    EventStore.append(%{
      stream_id: "worker-launch:#{run_id}",
      event_type: event_type,
      payload:
        Map.merge(payload, %{
          run_id: run_id,
          task_id: task.task_id,
          project_id: Map.get(task, :project_id),
          observed_at: DateTime.utc_now()
        }),
      metadata: %{correlation_id: run_id}
    })
  end

  defp append_task_failed(task, run_id, output) do
    EventStore.append(%{
      stream_id: "task:#{task.task_id}",
      event_type: "TaskUpdated",
      payload: %{
        task_id: task.task_id,
        status: "failed",
        run_id: run_id,
        failure_reason: "worker_launch_failed",
        failure_output: String.slice(output, 0, 2_000)
      },
      metadata: %{correlation_id: run_id}
    })
  end
end
