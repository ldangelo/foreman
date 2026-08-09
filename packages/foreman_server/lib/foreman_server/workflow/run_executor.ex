defmodule ForemanServer.Workflow.RunExecutor do
  @moduledoc """
  Per-run executor.

  Holds the in-memory run state (task projection, phase specs, current
  phase index) and drives each phase to completion by:

    1. Claiming the task through the configured task provider when the
       project has `task_provider` config.
    2. Emitting `PhaseStarted` via `CommandGateway.dispatch_system/1`.
    3. Invoking the configured agent (currently Pi) via
       `ForemanServer.AgentRuntime.invoke/1`.
    4. Writing any returned artifact through `ArtifactTemplate.write/4`.
    5. Emitting `PhaseCompleted` (or `PhaseFailed` + `TaskExecutionFailed`).
    6. Casting `{:advance_to, index}` to itself so the next phase runs.

  Every gateway call's result is pattern-matched explicitly with
  `dispatch_system/3` returning `{:ok, _}` or `{:error, reason}` — failures
  are logged and terminate the executor's run rather than being silently
  swallowed.

  `start_phase/2` is the orchestrator: it sequences start → execute →
  complete → enqueue-next, returning `{:ok, updated_state}` on success
  or `{:error, reason}`. It never confuses a phase result tuple with
  state.
  """

  use GenServer

  alias ForemanServer.AgentRuntime
  alias ForemanServer.CommandGateway
  alias ForemanServer.Identity
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.Workflow.Catalog

  require Logger

  @claim_lost_event [:foreman_server, :task_provider, :claim, :lost]
  @type state :: %{
          run_id: String.t(),
          task: map(),
          phase_specs: [map()],
          current_phase: non_neg_integer() | nil,
          completed: [non_neg_integer()],
          status: :ready | :in_progress | :completed | :failed,
          artifact_base: String.t(),
          plan_context: map() | nil
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

  @spec claim(String.t(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def claim(project_id, task_id, actor)
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" do
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :claim),
         result <- provider_module.claim(task_id, actor, project_config) do
      maybe_retry_lost_claim(result, provider_module, project_config, task_id)
    end
  end

  def claim(_project_id, _task_id, _actor), do: {:error, :invalid_claim}

  @spec complete(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def complete(project_id, task_id, run_id, artifact_path)
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" and
             is_binary(run_id) and run_id != "" do
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :close) do
      provider_module.complete(
        task_id,
        %{run_id: run_id, artifact_path: artifact_path},
        project_config
      )
    end
  end

  def complete(_project_id, _task_id, _run_id, _artifact_path),
    do: {:error, :invalid_completion}

  @spec fail(String.t(), String.t(), String.t(), term()) :: {:ok, term()} | {:error, term()}
  def fail(project_id, task_id, run_id, reason)
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" and
             is_binary(run_id) and run_id != "" do
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :reopen) do
      provider_module.fail(task_id, build_failure_token(run_id, reason), project_config)
    end
  end

  def fail(_project_id, _task_id, _run_id, _reason), do: {:error, :invalid_failure}

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

    plan_context =
      case plan_context_for(task_projection) do
        {:ok, ctx} -> ctx
        {:not_applicable, _} -> nil
        {:error, reason} -> %{__plan_context_error__: reason}
      end

    state = %{
      run_id: run_id,
      task: task_projection,
      phase_specs: phase_specs,
      current_phase: nil,
      completed: [],
      status: :ready,
      artifact_base: default_artifact_base(),
      plan_context: plan_context
    }

    Process.send_after(self(), :kickoff, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:kickoff, state) do
    case plan_context_error(state) do
      {:error, reason} ->
        Logger.warning(
          "RunExecutor plan context for #{state.run_id} rejected: #{inspect(reason)}"
        )

        _ = dispatch_task_execution_fail(state, {:plan_context_error, reason})
        {:stop, :normal, %{state | status: :failed}}

      :ok ->
        case maybe_claim_task(state) do
          :ok ->
            case start_phase_at_index(state, 0) do
              {:ok, next_state} -> {:noreply, next_state}
              {:noop, next_state} -> {:noreply, next_state}
              {:error, _reason} -> {:stop, :normal, state}
            end

          {:error, reason} ->
            Logger.warning("RunExecutor claim #{task_id(state)} failed: #{inspect(reason)}")
            {:stop, :normal, %{state | status: :failed}}
        end
    end
  end

  @impl true
  def handle_info({:start_at, index}, state) do
    case start_phase_at_index(state, index) do
      {:ok, next_state} -> {:noreply, next_state}
      {:noop, next_state} -> {:noreply, next_state}
      {:error, _reason} -> {:stop, :normal, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_cast({:advance_to, completed_index}, state) do
    completed = Enum.uniq(state.completed ++ [completed_index])
    next_index = completed_index + 1
    next_state = %{state | completed: completed}

    case Enum.at(state.phase_specs, next_index) do
      nil ->
        case finalize_run(next_state) do
          {:ok, finalized_state} -> {:noreply, finalized_state}
          {:error, _reason} -> {:stop, :normal, %{next_state | status: :failed}}
        end

      _phase_spec ->
        Process.send_after(self(), {:start_at, next_index}, 0)
        {:noreply, next_state}
    end
  end

  # Orchestrates: start → execute → complete → enqueue-next.
  # Returns {:ok, updated_state} on success or
  # {:error, reason} / {:noop, state} on failure / no-phase.
  defp start_phase_at_index(state, index) do
    case Enum.at(state.phase_specs, index) do
      nil ->
        case finalize_run(state) do
          {:ok, finalized_state} -> {:noop, finalized_state}
          {:error, reason} -> {:error, reason}
        end

      phase_spec ->
        run_single_phase(state, phase_spec, index)
    end
  end

  defp run_single_phase(state, phase_spec, index) do
    phase_index = phase_number(phase_spec, index)

    with {:ok, _} <- validate_phase_action(phase_spec, phase_index),
         {:ok, _} <- emit_phase_start(state, phase_spec, phase_index),
         {:ok, output} <- execute_agent(state, phase_spec, index),
         {:ok, artifact_path} <-
           __MODULE__.ArtifactTemplate.write(state, phase_spec, phase_index, output),
         {:ok, _required_file} <- enforce_required_file(state, phase_spec, phase_index),
         {:ok, artifact} <- __MODULE__.ArtifactTemplate.describe(artifact_path),
         {:ok, _} <- emit_phase_complete(state, phase_index, artifact) do
      next_state = %{state | current_phase: index, status: :in_progress}
      GenServer.cast(self(), {:advance_to, index})
      {:ok, next_state}
    else
      {:error, reason} ->
        case emit_phase_failure(state, phase_spec, phase_index, reason) do
          :ok -> {:error, reason}
          {:error, lifecycle_reason} -> {:error, lifecycle_reason}
        end
    end
  end

  defp validate_phase_action(phase_spec, _phase_index) do
    case Map.get(phase_spec, :action) do
      :command ->
        if is_binary(Map.get(phase_spec, :command)) and Map.get(phase_spec, :command) != "" do
          {:ok, :ok}
        else
          {:error, {:invalid_phase_command, phase_spec_name(phase_spec)}}
        end

      :bash ->
        {:error, {:unsupported_phase_action, :bash}}

      _ ->
        {:ok, :ok}
    end
  end

  defp emit_phase_start(state, phase_spec, phase_index) do
    phase_id = Identity.phase_id(state.run_id, phase_index)

    payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: phase_index,
      name: Map.get(phase_spec, :name) || Map.get(phase_spec, "name"),
      attempt: 1,
      artifact_template:
        Map.get(phase_spec, :artifact_template) ||
          Map.get(phase_spec, "artifact_template") || %{}
    }

    dispatch_system(
      "phase.start",
      payload,
      state.run_id,
      phase_id,
      "phase:#{state.run_id}:#{phase_id}"
    )
  end

  defp execute_agent(state, phase_spec, index) do
    phase_index = phase_number(phase_spec, index)
    request = build_request(state, phase_spec, phase_index)

    prompt =
      case Map.get(phase_spec, :action) do
        :command -> Map.get(phase_spec, :command) || request.prompt
        _ -> request.prompt
      end

    AgentRuntime.execute(
      prompt,
      request.context,
      backend: :pi,
      strategy: :manual,
      task_type: phase_spec_name(phase_spec)
    )
  end

  defmodule ArtifactTemplate do
    @moduledoc """
    Renders phase output to a file using the phase's `artifact_template`
    (defaults to a deterministic path under the run directory).
    """

    @spec path(map(), map(), pos_integer()) :: String.t()
    def path(state, phase_spec, index) do
      resolve_path(state, phase_spec, index)
    end

    @spec write(map(), map(), pos_integer(), term()) :: {:ok, String.t()} | {:error, term()}
    def write(state, phase_spec, index, output) do
      rendered = render(output)
      path = resolve_path(state, phase_spec, index)
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, rendered) do
        :ok -> {:ok, path}
        {:error, _} = error -> error
      end
    end

    @spec describe(String.t()) ::
            {:ok, %{path: String.t(), sha256: String.t(), bytes: non_neg_integer()}}
            | {:error, term()}
    def describe(path) when is_binary(path) do
      case File.read(path) do
        {:ok, contents} ->
          {:ok,
           %{
             path: path,
             sha256: ForemanServer.Identity.sha256(contents),
             bytes: byte_size(contents)
           }}

        {:error, _} = error ->
          error
      end
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
  end

  defp emit_phase_complete(state, phase_index, artifact) do
    phase_id = Identity.phase_id(state.run_id, phase_index)

    payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: phase_index,
      artifact_path: artifact.path,
      artifact_sha256: artifact.sha256,
      artifact_bytes: artifact.bytes
    }

    dispatch_system(
      "phase.complete",
      payload,
      state.run_id,
      phase_id,
      "phase:#{state.run_id}:#{phase_id}"
    )
  end

  defp emit_phase_failure(state, phase_spec, phase_index, reason) do
    Logger.warning(
      "RunExecutor phase #{phase_index} (#{phase_spec_name(phase_spec)}) failed: #{inspect(reason)}"
    )

    phase_id = Identity.phase_id(state.run_id, phase_index)

    fail_payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: phase_index,
      reason: inspect(reason)
    }

    with {:ok, _} <-
           dispatch_system(
             "phase.fail",
             fail_payload,
             state.run_id,
             phase_id,
             "phase:#{state.run_id}:#{phase_id}"
           ),
         :ok <- maybe_fail_task(state, phase_spec, phase_index, reason) do
      :ok
    end
  end

  defp finalize_run(state) do
    with :ok <- maybe_complete_task(state),
         {:ok, _} <- dispatch_run_complete(state) do
      {:ok, %{state | status: :completed}}
    end
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
    dispatch_system_command(
      type,
      "workflow:executor:#{type}:#{run_id}:#{suffix}",
      aggregate_id,
      payload
    )
  end

  defp dispatch_system_command(type, command_id, aggregate_id, payload) do
    case CommandGateway.dispatch_system(%{
           type: type,
           command_id: command_id,
           aggregate_id: aggregate_id,
           payload: payload
         }) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.error("RunExecutor dispatch #{type} (#{command_id}) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp base_context(state, phase_spec, index) do
    base = %{
      "phase_id" => Identity.phase_id(state.run_id, index),
      "run_id" => state.run_id,
      "task_id" => task_id(state),
      "working_directory" => working_directory(state.task)
    }

    base = Map.merge(base, state.plan_context || %{})
    Map.merge(base, Map.get(phase_spec, :context) || Map.get(phase_spec, "context") || %{})
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

  defp project_id(state) do
    Map.get(state.task, :project_id) || Map.get(state.task, "project_id") || ""
  end

  defp phase_spec_name(phase_spec) do
    Map.get(phase_spec, :name) || Map.get(phase_spec, "name") || ""
  end

  defp phase_number(phase_spec, index) do
    case Map.get(phase_spec, :index) || Map.get(phase_spec, "index") do
      value when is_integer(value) and value >= 1 -> value
      _ -> index + 1
    end
  end

  defp default_artifact_base do
    case System.fetch_env("HOME") do
      {:ok, home} -> Path.join([home, ".foreman", "runs"])
      _ -> Path.join([File.cwd!(), ".foreman", "runs"])
    end
  end

  defp maybe_claim_task(state) do
    case provider_enabled?(project_id(state)) do
      true ->
        claim(project_id(state), task_id(state), task_provider_actor()) |> to_lifecycle_result()

      false ->
        :ok
    end
  end

  defp maybe_complete_task(state) do
    case provider_enabled?(project_id(state)) do
      true ->
        case complete(
               project_id(state),
               task_id(state),
               state.run_id,
               completion_artifact_path(state)
             ) do
          {:ok, :already_terminal} -> :ok
          {:ok, _issue} -> dispatch_task_execution_complete(state)
          {:error, reason} -> {:error, reason}
        end

      false ->
        dispatch_task_execution_complete(state)
    end
  end

  defp maybe_fail_task(state, phase_spec, index, reason) do
    case provider_enabled?(project_id(state)) do
      true ->
        failure_reason =
          merge_failure_reason(reason, %{
            artifact_path: ArtifactTemplate.path(state, phase_spec, index)
          })

        case fail(project_id(state), task_id(state), state.run_id, failure_reason) do
          {:ok, _issue} -> dispatch_task_execution_fail(state, reason)
          {:error, failure_reason} -> {:error, failure_reason}
        end

      false ->
        dispatch_task_execution_fail(state, reason)
    end
  end

  defp dispatch_task_execution_complete(state) do
    dispatch_system_command(
      "task.execution_complete",
      Identity.task_complete_command_id(state.run_id),
      "task:#{task_id(state)}",
      %{task_id: task_id(state), run_id: state.run_id}
    )
    |> to_dispatch_result()
  end

  defp dispatch_task_execution_fail(state, reason) do
    dispatch_system_command(
      "task.execution_fail",
      Identity.task_fail_command_id(state.run_id),
      "task:#{task_id(state)}",
      %{task_id: task_id(state), run_id: state.run_id, reason: inspect(reason)}
    )
    |> to_dispatch_result()
  end

  defp dispatch_run_complete(state) do
    # Sequence is intentionally omitted — the Run aggregate normalizes a
    # nil/missing sequence against its in-memory `last_sequence`, so the
    # executor does not need to know the next expected version.
    dispatch_system_command(
      "run.complete",
      Identity.run_complete_command_id(state.run_id),
      "run:#{state.run_id}",
      %{run_id: state.run_id}
    )
  end

  defp resolve_provider(project_id, transition) do
    with {:ok, project} <- fetch_project_projection(project_id),
         {:ok, task_provider} <- fetch_task_provider(project),
         {:ok, project_config} <- fetch_project_config(task_provider),
         {:ok, database_path} <- fetch_database_path(project_config),
         {:ok, provider_module} <-
           TaskProviderRegistry.route(transition, {project_id, database_path}) do
      {:ok, provider_module, project_config}
    end
  end

  defp fetch_project_projection(project_id) do
    case ProjectionStore.project_projection(project_id) do
      %{} = project -> {:ok, project}
      _ -> {:error, :project_not_found}
    end
  end

  defp fetch_task_provider(project) do
    task_provider =
      Map.get(project, :task_provider) ||
        Map.get(project, "task_provider") ||
        get_in(project, [:config, :task_provider]) ||
        get_in(project, [:config, "task_provider"])

    if is_map(task_provider),
      do: {:ok, task_provider},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_project_config(task_provider) do
    project_config = Map.get(task_provider, :config) || Map.get(task_provider, "config")

    if is_map(project_config),
      do: {:ok, project_config},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_database_path(project_config) do
    case Map.get(project_config, :database_path) || Map.get(project_config, "database_path") do
      database_path when is_binary(database_path) and database_path != "" -> {:ok, database_path}
      _ -> {:error, :task_provider_not_configured}
    end
  end

  defp provider_enabled?(project_id) when is_binary(project_id) and project_id != "" do
    case fetch_project_projection(project_id) do
      {:ok, project} -> match?({:ok, _}, fetch_task_provider(project))
      {:error, _reason} -> false
    end
  end

  defp provider_enabled?(_project_id), do: false

  defp completion_artifact_path(state) do
    index =
      cond do
        is_integer(state.current_phase) ->
          state.current_phase

        state.phase_specs == [] ->
          nil

        true ->
          length(state.phase_specs) - 1
      end

    case index do
      idx when is_integer(idx) and idx >= 0 ->
        phase_spec = Enum.at(state.phase_specs, idx) || %{}
        ArtifactTemplate.path(state, phase_spec, phase_number(phase_spec, idx))

      _ ->
        nil
    end
  end

  defp build_failure_token(run_id, reason) do
    failure_reason = normalize_failure_reason(reason)

    artifact_path =
      Map.get(failure_reason, :artifact_path) || Map.get(failure_reason, "artifact_path")

    transition_comment =
      case normalized_transition_comment(
             Map.get(failure_reason, :transition_comment) ||
               Map.get(failure_reason, "transition_comment")
           ) do
        nil -> default_transition_comment(run_id, artifact_path)
        comment -> comment
      end

    failure_reason
    |> Map.put(:run_id, run_id)
    |> Map.put(:artifact_path, artifact_path)
    |> Map.put(:transition_comment, transition_comment)
  end

  defp normalize_failure_reason(%{} = reason), do: reason
  defp normalize_failure_reason(reason), do: %{reason: inspect(reason)}

  defp merge_failure_reason(%{} = reason, extra), do: Map.merge(reason, extra)
  defp merge_failure_reason(reason, extra), do: Map.put(extra, :reason, inspect(reason))

  defp normalized_transition_comment(comment) when is_binary(comment) do
    case String.trim(comment) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_transition_comment(_comment), do: nil

  defp default_transition_comment(run_id, artifact_path) do
    "foreman-run:#{run_id}:#{artifact_path}"
  end

  defp maybe_retry_lost_claim(
         {:error, %{code: "NOT_CLAIMABLE"} = error},
         provider_module,
         project_config,
         task_id
       ) do
    case provider_module.list_ready(project_config, []) do
      {:ok, issues} when is_list(issues) ->
        if Enum.any?(issues, &issue_matches_task_id?(&1, task_id)) do
          {:error, error}
        else
          TaskProviderTelemetry.emit(@claim_lost_event, %{count: 1}, %{})
          {:error, error}
        end

      _other ->
        {:error, error}
    end
  end

  defp maybe_retry_lost_claim(result, _provider_module, _project_config, _task_id), do: result

  defp issue_matches_task_id?(issue, task_id) when is_map(issue) do
    Map.get(issue, :id) == task_id || Map.get(issue, "id") == task_id
  end

  defp issue_matches_task_id?(_issue, _task_id), do: false

  defp task_provider_actor do
    Application.get_env(:foreman_server, :task_provider, [])
    |> Keyword.get(:actor)
  end

  defp to_lifecycle_result({:ok, _result}), do: :ok
  defp to_lifecycle_result({:error, reason}), do: {:error, reason}

  defp to_dispatch_result({:ok, _result}), do: :ok
  defp to_dispatch_result({:error, reason}), do: {:error, reason}

  defp plan_context_for(task_projection) do
    ForemanServer.Workflow.PlanContext.build(task_projection)
  end

  defp plan_context_error(state) do
    case Map.get(state.plan_context || %{}, :__plan_context_error__) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp enforce_required_file(state, phase_spec, phase_index) do
    case Map.get(phase_spec, :required_file) do
      nil ->
        {:ok, :no_gate}

      "" ->
        {:error, {:required_file_blank, phase_index}}

      key when is_binary(key) ->
        case resolve_context_key(state, key, phase_index) do
          {:ok, path} ->
            if is_binary(path) and File.regular?(path) do
              {:ok, path}
            else
              {:error, {:required_file_missing, key, path}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:required_file_invalid, phase_index}}
    end
  end

  defp resolve_context_key(state, key, phase_index) when is_binary(key) do
    segments = String.split(key, ".", trim: true)

    cond do
      segments == [] -> {:error, {:required_file_blank_key, key}}
      Enum.any?(segments, &(&1 == "")) -> {:error, {:required_file_blank_segment, key}}
      true -> traverse_context_key(context_for(state, phase_index), segments)
    end
  end

  defp context_for(state, phase_index) do
    base = %{
      "phase_id" => Identity.phase_id(state.run_id, phase_index),
      "run_id" => state.run_id,
      "task_id" => task_id(state)
    }

    Map.merge(base, state.plan_context || %{})
  end

  defp traverse_context_key(_ctx, []), do: {:error, :required_file_traversal_failed}

  defp traverse_context_key(ctx, [segment]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      nil -> {:error, {:required_file_unknown_key, segment}}
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, {:required_file_invalid_path, segment}}
    end
  end

  defp traverse_context_key(ctx, [segment | rest]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      %{} = next -> traverse_context_key(next, rest)
      _ -> {:error, {:required_file_unknown_key, segment}}
    end
  end
end
