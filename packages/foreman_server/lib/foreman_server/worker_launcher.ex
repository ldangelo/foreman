defmodule ForemanServer.WorkerLauncher do
  @moduledoc "Launches the Node/Pi worker bridge for scheduler-claimed tasks."

  alias ForemanServer.EventStore

  @spec launch(map(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def launch(task, run_id, phases) when is_map(task) and is_binary(run_id) do
    task_id = Map.fetch!(task, :task_id)

    with {:ok, project_path} <- project_path(task),
         {:ok, foreman} <- foreman_executable() do
      workflow = workflow_name(task)

      args = [
        "run",
        "task",
        task_id,
        workflow,
        "--project-path",
        project_path,
        "--no-watch",
        "--run-id",
        run_id
      ]

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

          maybe_append_worker_spawned_event(task, run_id, workflow, output)

          append_missing_terminal_event(task, run_id, workflow, status, output)
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
    case System.get_env("FOREMAN_EXECUTABLE") do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        case System.find_executable("foreman") do
          nil -> {:error, :foreman_executable_not_found}
          path -> {:ok, path}
        end
    end
  end

  defp worker_env do
    env =
      [
        {"FOREMAN_SERVER_URL", server_url()},
        {"FOREMAN_SERVER_HTTP_ENABLED", "false"},
        {"FOREMAN_SERVER_HTTP_PORT", "0"}
      ]
      |> maybe_put_env("FOREMAN_RUNTIME_MODE")
      |> maybe_put_env("FOREMAN_PHASE_RUNNER_MODULE")
      |> maybe_put_env("FOREMAN_HOME")

    env =
      case ForemanServer.Security.auth_token() do
        token when is_binary(token) and token != "" ->
          [{"FOREMAN_WORKER_EVENT_TOKEN", token} | env]

        _ ->
          env
      end

    env
  end

  defp maybe_put_env(env, key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> [{key, value} | env]
      _ -> env
    end
  end

  defp server_url do
    "http://127.0.0.1:#{ForemanServer.RuntimeInfo.http_port()}"
  end

  defp workflow_name(task) do
    Map.get(task, :workflow) || Map.get(task, :task_type) || Map.get(task, :type) || "feature"
  end

  defp append_missing_terminal_event(task, run_id, workflow, exit_code, output) do
    run = get_in(ForemanServer.ProjectionStore.snapshot(), [:runs, run_id]) || %{}

    unless Map.get(run, :status) in ["completed", "failed", "blocked"] do
      inferred = infer_terminal_failure(output)

      unless bridge_completed_successfully?(exit_code, inferred) or
               detached_worker_started?(output) do
        phase_id = inferred.phase_id || Map.get(run, :current_phase)

        append("RunFailed", task, run_id, %{
          workflow: workflow,
          exit_code: exit_code,
          phase_id: phase_id,
          reason: inferred.reason || "worker_exited_without_terminal_event",
          diagnostic_reason: "worker_exited_without_terminal_event"
        })
      end
    end
  end

  defp bridge_completed_successfully?(0, %{phase_id: nil, reason: nil}), do: true
  defp bridge_completed_successfully?(_exit_code, _inferred), do: false

  defp detached_worker_started?(output) when is_binary(output) do
    String.contains?(output, "Worker spawned (pid=")
  end

  defp detached_worker_started?(_output), do: false

  defp maybe_append_worker_spawned_event(task, run_id, workflow, output) when is_binary(output) do
    case Regex.run(~r/Worker spawned \(pid=(\d+)\)/, output) do
      [_match, pid] ->
        append("WorkerSpawned", task, run_id, %{
          workflow: workflow,
          worker_pid: String.to_integer(pid),
          log_path: Path.join([System.user_home!(), ".foreman", "logs", "#{run_id}.log"])
        })

      _ ->
        :ok
    end
  end

  defp maybe_append_worker_spawned_event(_task, _run_id, _workflow, _output), do: :ok

  defp infer_terminal_failure(output) when is_binary(output) do
    normalized_output = String.replace(output, "—", "-")

    %{
      phase_id: infer_failed_phase(normalized_output),
      reason: infer_failure_reason(normalized_output)
    }
  end

  defp infer_terminal_failure(_output), do: %{phase_id: nil, reason: nil}

  defp infer_failed_phase(output) do
    patterns = [
      ~r/FAILED\s+[—-]\s+\s*\S+\s+\[([^\]]+)\]/,
      ~r/\[PIPELINE\]\s+([A-Za-z0-9_-]+)\s+failed after \d+ retries/i,
      ~r/\[PIPELINE\]\s+([A-Za-z0-9_-]+)\s+FAIL:/i,
      ~r/\[([A-Za-z0-9_-]+)\]\s+FAIL\s+[—-]/i,
      ~r/\[PHASE:\s*([^\]]+)\]\s+FAILED/i
    ]

    patterns
    |> Enum.flat_map(fn pattern -> Regex.scan(pattern, output, return: :index) end)
    |> Enum.map(fn [{start, _} | captures] ->
      {capture_text(output, captures), start}
    end)
    |> Enum.reject(fn {phase, _start} -> is_nil(phase) or phase == "" end)
    |> Enum.max_by(fn {_phase, start} -> start end, fn -> {nil, nil} end)
    |> elem(0)
    |> normalize_phase()
  end

  defp infer_failure_reason(output) do
    reasons =
      Regex.scan(~r/\[PIPELINE\]\s+([A-Za-z0-9_-]+)\s+failed after \d+ retries/i, output,
        return: :index
      )
      |> Enum.map(fn [{start, _}, phase_capture] ->
        phase = capture_text(output, [phase_capture]) |> normalize_phase()
        {"#{phase}_failed", start}
      end)

    pipeline_fail_reasons =
      Regex.scan(~r/\[PIPELINE\]\s+([A-Za-z0-9_-]+)\s+FAIL:\s*([^\n]+)/i, output, return: :index)
      |> Enum.map(fn [{start, _}, _phase_capture, reason_capture] ->
        {capture_text(output, [reason_capture]) |> String.trim(), start}
      end)

    phase_fail_reasons =
      Regex.scan(~r/\[([A-Za-z0-9_-]+)\]\s+FAIL\s+[^\n]+/i, output, return: :index)
      |> Enum.map(fn [{start, length}, _phase_capture] ->
        {output |> binary_part(start, length) |> reason_after_fail(), start}
      end)

    case Enum.max_by(
           reasons ++ pipeline_fail_reasons ++ phase_fail_reasons,
           fn {_reason, start} -> start end,
           fn -> {nil, nil} end
         ) do
      {reason, _start} when is_binary(reason) and reason != "" ->
        reason

      _ ->
        if String.contains?(output, "Run completed: failed") or
             String.contains?(output, "[PIPELINE] FAILED") do
          "pipeline_failed"
        end
    end
  end

  defp capture_text(output, [{start, length} | _]) do
    binary_part(output, start, length)
  end

  defp capture_text(_output, _captures), do: nil

  defp reason_after_fail(line) do
    line
    |> String.split(~r/\s+FAIL\s+/i, parts: 2)
    |> List.last()
    |> String.replace(~r/^[—-]\s*/, "")
    |> String.trim()
  end

  defp normalize_phase(phase) when is_binary(phase) do
    phase
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_phase(_phase), do: nil

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
