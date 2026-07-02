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

          append("WorkerProcessExited", task, run_id, %{
            workflow: workflow,
            exit_code: status,
            output: output
          })

          append_missing_terminal_event(task, run_id, workflow, status)
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
    env = [
      {"FOREMAN_BACKEND", "node"},
      {"FOREMAN_SERVER_URL", server_url()},
      {"FOREMAN_SERVER_HTTP_ENABLED", "false"},
      {"FOREMAN_SERVER_HTTP_PORT", "0"}
    ]
    env =
      case ForemanServer.Security.auth_token() do
        token when is_binary(token) and token != "" -> [{"FOREMAN_WORKER_EVENT_TOKEN", token} | env]
        _ -> env
      end

    case database_url() do
      nil -> env
      url -> [{"DATABASE_URL", url} | env]
    end
  end

  defp server_url do
    port = Application.get_env(:foreman_server, :http_port) ||
      String.to_integer(System.get_env("FOREMAN_SERVER_HTTP_PORT") || "4766")

    "http://127.0.0.1:#{port}"
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

  defp append_missing_terminal_event(task, run_id, workflow, exit_code) do
    run = get_in(ForemanServer.ProjectionStore.snapshot(), [:runs, run_id]) || %{}

    unless Map.get(run, :status) in ["completed", "failed", "blocked"] do
      append("RunFailed", task, run_id, %{
        workflow: workflow,
        exit_code: exit_code,
        phase_id: Map.get(run, :current_phase),
        reason: "worker_exited_without_terminal_event"
      })
    end
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

end
