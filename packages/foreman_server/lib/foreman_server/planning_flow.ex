defmodule ForemanServer.PlanningFlow do
  @moduledoc "Event-backed PRD/TRD planning flow execution through the worker pipeline."

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, WorkerProtocol}

  @compat_commands %{
    "/ensemble:create-prd" => "/ensemble:create-prd",
    "/skill:ensemble-create-prd" => "/skill:ensemble-create-prd",
    "/ensemble:create-trd" => "/ensemble:create-trd",
    "/ensemble:refine-prd" => "/ensemble:refine-prd",
    "/ensemble:refine-trd" => "/ensemble:refine-trd"
  }

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(input) when is_map(input) do
    input = normalize(input)

    with {:ok, kind} <- planning_kind(Map.get(input, :kind, Map.get(input, :plan_type))),
         {:ok, project_id} <- required_binary(Map.get(input, :project_id), :project_id),
         {:ok, description} <-
           required_binary(Map.get(input, :description, Map.get(input, :input)), :description),
         {:ok, adapter} <- adapter(Map.get(input, :adapter, Map.get(input, :provider, "pi_sdk"))),
         {:ok, run_id} <-
           required_binary(
             Map.get(input, :run_id, default_run_id(kind, project_id, description)),
             :run_id
           ) do
      output_dir = Map.get(input, :output_dir, "docs")
      compatibility = compatibility_enabled?(input)
      phases = phases(kind, description, output_dir, compatibility, Map.get(input, :from_prd))

      with {:ok, started} <-
             append_planning_started(
               run_id,
               kind,
               project_id,
               description,
               output_dir,
               compatibility,
               phases
             ),
           {:ok, phase_results} <- execute_phases(run_id, project_id, phases, adapter),
           {:ok, trace_events} <-
             append_traceability(run_id, project_id, kind, phases, phase_results),
           {:ok, task_results} <-
             create_planning_tasks(run_id, project_id, kind, phases, trace_events),
           {:ok, completed} <-
             append_planning_completed(run_id, kind, project_id, phases, task_results) do
        {:ok,
         %{
           run_id: run_id,
           kind: Atom.to_string(kind),
           event: completed,
           started: started,
           phases: phase_results,
           traceability: trace_events,
           tasks: task_results,
           projection: ProjectionStore.snapshot()
         }}
      end
    end
  end

  defp execute_phases(run_id, project_id, phases, adapter) do
    phases
    |> Enum.reduce_while({:ok, []}, fn phase, {:ok, acc} ->
      phase_id = phase.id
      worker_id = "planning-#{phase_id}"

      with {:ok, _started} <-
             WorkerProtocol.start_phase(phase_id, %{
               run_id: run_id,
               worker_id: worker_id,
               adapter: adapter,
               model: "pi/planning",
               tool_names: ["bash", "read", "write"],
               prompt_path: phase.artifact_path,
               artifact_paths: [phase.artifact_path]
             }),
           {:ok, worker_event} <-
             WorkerProtocol.ingest_event(%{
               run_id: run_id,
               phase_id: phase_id,
               worker_id: worker_id,
               type: "phase_completed",
               sequence: 1,
               output: phase.output,
               message: phase.prompt,
               artifact_paths: [phase.artifact_path],
               report_paths: [phase.artifact_path],
               exit_code: 0,
               details: %{
                 planning_phase: phase.name,
                 command: phase.command,
                 compatibility_mode: phase.compatibility_mode,
                 project_id: project_id
               }
             }) do
        result = %{
          phase_id: phase_id,
          command: phase.command,
          artifact_path: phase.artifact_path,
          worker_event_id: worker_event.event.event_id
        }

        {:cont, {:ok, acc ++ [result]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp append_traceability(run_id, project_id, kind, phases, phase_results) do
    phases
    |> Enum.zip(phase_results)
    |> Enum.reduce_while({:ok, []}, fn {phase, result}, {:ok, acc} ->
      payload = %{
        run_id: run_id,
        project_id: project_id,
        planning_kind: Atom.to_string(kind),
        phase_id: phase.id,
        command: phase.command,
        source_artifact: phase.source_artifact,
        artifact_path: phase.artifact_path,
        worker_event_id: result.worker_event_id,
        traceability_key: "#{run_id}:#{phase.id}"
      }

      case append_event(
             "planning:#{run_id}",
             "PlanningTraceLinked",
             payload,
             "trace:#{run_id}:#{phase.id}"
           ) do
        {:ok, event} -> {:cont, {:ok, acc ++ [event]}}
        error -> {:halt, error}
      end
    end)
  end

  defp create_planning_tasks(run_id, project_id, kind, phases, trace_events) do
    phases
    |> Enum.zip(trace_events)
    |> Enum.reduce_while({:ok, []}, fn {phase, trace_event}, {:ok, acc} ->
      task_id = "plan-#{run_id}-#{phase.id}"

      command = %{
        command_id: "planning-task:#{task_id}",
        command_type: "task.create",
        payload: %{
          task_id: task_id,
          project_id: project_id,
          title: phase.name,
          status: "open",
          task_type: "planning",
          source: "planning_flow",
          external_id: trace_event.payload.traceability_key,
          external_link: phase.artifact_path,
          dedupe_key: "planning:#{run_id}:#{phase.id}",
          integration_event_type: "PlanningTraceLinked",
          planning_run_id: run_id,
          planning_kind: Atom.to_string(kind),
          planning_phase_id: phase.id,
          trace_event_id: trace_event.event_id
        }
      }

      case CommandRouter.handle(command) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result.event]}}
        error -> {:halt, error}
      end
    end)
  end

  defp append_planning_started(
         run_id,
         kind,
         project_id,
         description,
         output_dir,
         compatibility,
         phases
       ) do
    append_event(
      "planning:#{run_id}",
      "PlanningFlowStarted",
      %{
        run_id: run_id,
        project_id: project_id,
        planning_kind: Atom.to_string(kind),
        description: description,
        output_dir: output_dir,
        compatibility_mode: compatibility,
        phase_order: Enum.map(phases, & &1.id)
      },
      "planning-started:#{run_id}"
    )
  end

  defp append_planning_completed(run_id, kind, project_id, phases, task_results) do
    append_event(
      "planning:#{run_id}",
      "PlanningFlowCompleted",
      %{
        run_id: run_id,
        project_id: project_id,
        planning_kind: Atom.to_string(kind),
        phase_order: Enum.map(phases, & &1.id),
        task_ids: Enum.map(task_results, & &1.payload.task_id)
      },
      "planning-completed:#{run_id}"
    )
  end

  defp append_event(stream_id, event_type, payload, idempotency_key) do
    EventStore.append(%{
      stream_id: stream_id,
      event_type: event_type,
      payload: Map.put(payload, :observed_at, DateTime.utc_now()),
      metadata: %{
        correlation_id: Map.get(payload, :run_id),
        idempotency_key: idempotency_key
      }
    })
  end

  defp phases(:prd, description, output_dir, compatibility, _from_prd) do
    [
      phase(
        "create-prd",
        "Create PRD",
        command("/ensemble:create-prd", compatibility),
        description,
        Path.join(output_dir, "PRD.md"),
        nil,
        compatibility
      ),
      phase(
        "refine-prd",
        "Refine PRD",
        "/ensemble:refine-prd",
        "Review and refine the PRD in #{output_dir}",
        Path.join(output_dir, "PRD.md"),
        Path.join(output_dir, "PRD.md"),
        compatibility
      )
    ]
  end

  defp phases(:trd, description, output_dir, compatibility, from_prd) do
    source = from_prd || Path.join(output_dir, "PRD.md")

    [
      phase(
        "create-trd",
        "Create TRD",
        "/ensemble:create-trd",
        source,
        Path.join(output_dir, "TRD.md"),
        source,
        compatibility
      ),
      phase(
        "refine-trd",
        "Refine TRD",
        "/ensemble:refine-trd",
        "Review and refine the TRD in #{output_dir}: #{description}",
        Path.join(output_dir, "TRD.md"),
        Path.join(output_dir, "TRD.md"),
        compatibility
      )
    ]
  end

  defp phase(id, name, command, prompt, artifact_path, source_artifact, compatibility) do
    %{
      id: id,
      name: name,
      command: command,
      prompt: "#{command} #{prompt}",
      output: "planning artifact prepared: #{artifact_path}",
      artifact_path: artifact_path,
      source_artifact: source_artifact,
      compatibility_mode: compatibility
    }
  end

  defp command(command, false), do: command

  defp command("/ensemble:create-prd", true),
    do: Map.fetch!(@compat_commands, "/ensemble:create-prd")

  defp command(command, true), do: Map.get(@compat_commands, command, command)

  defp planning_kind(kind) when kind in [:prd, "prd"], do: {:ok, :prd}
  defp planning_kind(kind) when kind in [:trd, "trd"], do: {:ok, :trd}
  defp planning_kind(value), do: {:error, {:unsupported_planning_kind, value}}

  defp adapter(value) when value in [:pi, :pi_sdk, "pi", "pi_sdk"], do: {:ok, "pi_sdk"}
  defp adapter(value), do: {:error, {:unsupported_provider, value}}

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp compatibility_enabled?(input),
    do: Map.get(input, :compatibility_mode, false) in [true, "true", "1"]

  defp default_run_id(kind, project_id, description) do
    digest =
      :crypto.hash(:sha256, "#{kind}:#{project_id}:#{description}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "planning-#{kind}-#{digest}"
  end

  defp normalize(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        if key in known_string_keys() do
          {String.to_existing_atom(key), normalize_value(value)}
        else
          {key, normalize_value(value)}
        end

      {key, value} ->
        {key, normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: normalize(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp known_string_keys do
    ~w(adapter compatibility_mode description from_prd input kind output_dir plan_type project_id provider run_id)
  end
end
