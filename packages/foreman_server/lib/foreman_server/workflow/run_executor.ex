defmodule ForemanServer.Workflow.RunExecutor do
  @moduledoc """
  Per-run executor.

  Holds the in-memory run state (task projection, phase specs, current
  phase index) and drives each phase to completion by:

    1. Emitting `PhaseStarted` via `CommandGateway.dispatch_system/1`.
    2. Invoking the configured agent (currently Pi) via
       `ForemanServer.AgentRuntime.invoke/1`.
    3. Writing any returned artifact through `ArtifactTemplate.write/2`.
    4. Emitting `PhaseCompleted` (or `PhaseFailed` + `TaskExecutionFailed`).
    5. Casting `{:advance_to, index}` to itself so the next phase runs.

  Every gateway call's result is pattern-matched explicitly with
  `dispatch_system/3` returning `{:ok, _}` or `{:error, reason}` — failures
  are logged and terminate the executor's run rather than being silently
  swallowed.

  `start_phase/2` is the orchestrator: it sequences start → execute →
  complete → enqueue-next, returning `{:ok, updated_state}` on success
  or `{:error, reason}` on failure. It never confuses a phase result
  tuple with state.
  """

  use GenServer

  alias ForemanServer.AgentRuntime
  alias ForemanServer.CommandGateway
  alias ForemanServer.Identity
  alias ForemanServer.Workflow.Catalog

  require Logger

  @type phase_spec :: map()
  @type state :: %{
          run_id: String.t(),
          task: map(),
          phase_specs: [phase_spec],
          current_phase: non_neg_integer() | nil,
          completed: [non_neg_integer()],
          status: :ready | :in_progress | :completed | :failed
        }

  @spec start_link(String.t(), map()) :: GenServer.on_start()
  def start_link(run_id, task_projection) do
    GenServer.start_link(
      __MODULE__,
      {run_id, task_projection},
      name: via_tuple(run_id)
    )
  end

  @spec advance_to(String.t(), non_neg_integer()) :: :ok
  def advance_to(run_id, completed_index) do
    GenServer.cast(via_tuple(run_id), {:advance_to, completed_index})
  end

  @spec pid_for(String.t()) :: pid() | nil
  def pid_for(run_id) do
    case Registry.lookup(ForemanServer.RunExecutorRegistry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via_tuple(run_id) do
    {:via, Registry, {ForemanServer.RunExecutorRegistry, run_id}}
  end

  @impl true
  def init({run_id, task_projection}) do
    phase_specs =
      case task_projection do
        %{workflow_snapshot: %{phases: phases}} when is_list(phases) -> phases
        _ -> []
      end

    state = %{
      run_id: run_id,
      task: task_projection,
      phase_specs: phase_specs,
      current_phase: nil,
      completed: [],
      status: :ready,
      artifact_base: default_artifact_base()
    }

    Process.send_after(self(), :kickoff, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:kickoff, state) do
    case start_phase_at_index(state, 0) do
      {:ok, state} -> {:noreply, state}
      {:noop, state} -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:advance_to, completed_index}, state) do
    completed = Enum.uniq(state.completed ++ [completed_index])

    next_index = completed_index + 1

    case Enum.at(state.phase_specs, next_index) do
      nil ->
        finalize_run(%{state | completed: completed})
        {:noreply, state}

      _phase_spec ->
        Process.send_after(self(), {:start_at, next_index}, 0)
        {:noreply, %{state | completed: completed}}
    end
  end

  @impl true
  def handle_info({:start_at, index}, state) do
    case start_phase_at_index(state, index) do
      {:ok, state} -> {:noreply, state}
      {:noop, state} -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  # Orchestrates: start → execute → complete → enqueue-next.
  # Returns {:ok, updated_state} on success or
  # {:error, reason} / {:noop, state} on failure / no-phase.
  defp start_phase_at_index(state, index) do
    case Enum.at(state.phase_specs, index) do
      nil ->
        finalize_run(state)
        {:noop, %{state | status: :completed}}

      phase_spec ->
        run_single_phase(state, phase_spec, index)
    end
  end

  defp run_single_phase(state, phase_spec, index) do
    phase_id = Identity.phase_id(state.run_id, index)

    with {:ok, _} <- emit_phase_start(state, phase_spec, index),
         {:ok, output} <- execute_agent(state, phase_spec),
         :ok <- ArtifactTemplate.write(state, phase_spec, index, output),
         {:ok, _} <- emit_phase_complete(state, phase_spec, index) do
      state = %{state | current_phase: index, status: :in_progress}
      GenServer.cast(self(), {:advance_to, index})
      {:ok, state}
    else
      {:error, reason} ->
        emit_phase_failure(state, phase_spec, index, reason)
        {:error, reason}
    end
  end

  defp emit_phase_start(state, phase_spec, index) do
    phase_id = Identity.phase_id(state.run_id, index)

    payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: index,
      name: Map.get(phase_spec, :name) || Map.get(phase_spec, "name"),
      attempt: 1,
      artifact_template: Map.get(phase_spec, :artifact_template) ||
                          Map.get(phase_spec, "artifact_template") || %{}
    }

    dispatch_system("phase.start", payload, state.run_id, phase_id, "phase:#{state.run_id}:#{phase_id}")
  end

  defp execute_agent(state, phase_spec) do
    index = Map.get(phase_spec, :index) || 0
    request = build_request(state, phase_spec, index)
    AgentRuntime.execute(request.prompt, request.context, backend: :pi, strategy: :manual, task_type: phase_spec_name(phase_spec))
  end

  defmodule ArtifactTemplate do
    @moduledoc """
    Renders phase output to a file using the phase's `artifact_template`
    (defaults to a deterministic path under the run directory).
    """

    @spec write(map(), map(), pos_integer(), term()) :: :ok | {:error, term()}
    def write(state, phase_spec, index, output) do
      rendered = render(output)
      path = resolve_path(state, phase_spec, index)
      File.mkdir_p!(Path.dirname(path))
      File.write(path, rendered)
    end

    defp render(output) when is_binary(output), do: output
    defp render(output), do: inspect(output)

    defp resolve_path(state, phase_spec, index) do
      template = phase_template(phase_spec)

      case template[:path] || template["path"] do
        nil -> default_path(state, index)
        "" -> default_path(state, index)
        path when is_binary(path) -> expand(path, state)
      end
    end

    defp phase_template(phase_spec) do
      Map.get(phase_spec, :artifact_template) || Map.get(phase_spec, "artifact_template") || %{}
    end

    defp expand(path, state) do
      String.replace(path, "{run_id}", state.run_id)
      |> String.replace("{task_id}", task_id_of(state))
    end

    defp default_path(state, index) do
      Path.join([state.artifact_base, state.run_id, "phase-#{index}.md"])
    end

    defp task_id_of(state) do
      Map.get(state.task, :task_id) || Map.get(state.task, "task_id") || "unknown"
    end

    defp working_directory_safe do
      case System.fetch_env("HOME") do
        {:ok, home} -> home
        _ -> File.cwd!()
      end
    end
  end

  defp emit_phase_complete(state, phase_spec, index) do
    phase_id = Identity.phase_id(state.run_id, index)

    payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: index
    }

    dispatch_system("phase.complete", payload, state.run_id, phase_id, "phase:#{state.run_id}:#{phase_id}")
  end

  defp emit_phase_failure(state, phase_spec, index, reason) do
    Logger.warning("RunExecutor phase #{index} (#{phase_spec_name(phase_spec)}) failed: #{inspect(reason)}")

    phase_id = Identity.phase_id(state.run_id, index)

    fail_payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: index,
      reason: inspect(reason)
    }

    _ = dispatch_system("phase.fail", fail_payload, state.run_id, phase_id, "phase:#{state.run_id}:#{phase_id}")
    _ = dispatch_system("task.execution_fail", %{task_id: task_id(state), run_id: state.run_id, reason: inspect(reason)}, state.run_id, phase_id, "task:#{task_id(state)}")
    :ok
  end

  defp finalize_run(state) do
    payload = %{
      run_id: state.run_id,
      task_id: task_id(state),
      status: "completed"
    }

    _ = dispatch_system("run.complete", payload, state.run_id, "final", "run:#{state.run_id}")
    _ = dispatch_system("task.execution_complete", %{task_id: task_id(state), run_id: state.run_id}, state.run_id, "final", "task:#{task_id(state)}")
    :ok
  end

  defp build_request(state, phase_spec, index) do
    %{
      context: base_context(state, phase_spec, index),
      prompt: read_phase_prompt(state, phase_spec)
    }
  end

  defp read_phase_prompt(_state, phase_spec) do
    case Map.get(phase_spec, :prompt_path) || Map.get(phase_spec, "prompt_path") do
      nil ->
        "Run phase #{phase_spec_name(phase_spec)}"

      "" ->
        "Run phase #{phase_spec_name(phase_spec)}"

      path when is_binary(path) ->
        case Catalog.read_prompt(path) do
          {:ok, content} ->
            content

          {:error, :prompt_not_tracked} ->
            raise "RunExecutor: prompt file #{path} is not tracked by the workflow catalog"
        end
    end
  end

  defp dispatch_system(type, payload, run_id, suffix, aggregate_id) do
    command_id = "workflow:executor:#{type}:#{run_id}:#{suffix}"

    case CommandGateway.dispatch_system(%{
           type: type,
           command_id: command_id,
           aggregate_id: aggregate_id,
           payload: payload
         }) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.error("RunExecutor dispatch #{type} (#{suffix}) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
  defp base_context(state, phase_spec, index) do
    %{
      "phase_id" => Identity.phase_id(state.run_id, index),
      "run_id" => state.run_id,
      "task_id" => task_id(state),
      "working_directory" => working_directory(state.task)
    }
    |> Map.merge(Map.get(phase_spec, :context) || Map.get(phase_spec, "context") || %{})
  end

  defp working_directory(task) do
    case Map.get(task, :working_directory) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.fetch_env!("HOME")
    end
  end

  defp task_id(state) do
    Map.get(state.task, :task_id) || Map.get(state.task, "task_id") ||
      Map.get(state.task, :id) || Map.get(state.task, "id") || ""
  end

  defp phase_spec_name(phase_spec) do
    Map.get(phase_spec, :name) || Map.get(phase_spec, "name") || ""
  end

  defp default_artifact_base do
    case System.fetch_env("HOME") do
      {:ok, home} -> Path.join(home, ".foreman", "runs")
      _ -> Path.join(File.cwd!(), ".foreman", "runs")
    end
  end
end