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
  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.CommandGateway
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.EventStore, as: EventStore
  alias ForemanServer.Idempotency.HeartbeatLease
  alias ForemanServer.RunExecutorLiveness
  alias ForemanServer.Identity
  alias ForemanServer.Overwatch
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Agents.VfsIsolation
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.Workflow.Worktree
  require Logger
  @claim_lost_event [:foreman_server, :task_provider, :claim, :lost]
  @type state :: %{
          task: map(),
          phase_specs: [map()],
          current_phase: non_neg_integer() | nil,
          completed: [non_neg_integer()],
          phase_statuses: %{
            non_neg_integer() => :in_progress | :completed | :failed | :blocked | :skipped
          },
          status: :ready | :in_progress | :completed | :failed | :blocked,
          artifact_base: String.t(),
          plan_context: map() | nil,
          source: :task | :work_request | :unknown
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

  # The `task_projection` is the in-memory snapshot Foreman's
  # `ProjectionStore` builds after deserializing the `TaskApproved`
  # event payload. The outer map uses atom keys (`:workflow_snapshot`,
  # `:run_id`, …) but the inner `workflow_snapshot` value carries
  # JSON-decoded string keys only. Match the dual-key shape so phases
  # are never silently dropped — the previous atom-only pattern match
  # fell through to `[]` whenever the projection arrived via the
  # persisted/JSON-decoded path.
  defp extract_phase_specs(task) do
    snapshot =
      Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

    case Map.get(snapshot, :phases) || Map.get(snapshot, "phases") do
      phases when is_list(phases) -> phases
      _ -> []
    end
  end

  @impl true
  def init({run_id, task_projection}) do
    phase_specs = extract_phase_specs(task_projection)

    plan_context =
      case plan_context_for(task_projection) do
        {:ok, ctx} -> ctx
        {:not_applicable, _} -> nil
        {:error, reason} -> %{__plan_context_error__: reason}
      end

    source =
      cond do
        Map.get(task_projection, :task_id) || Map.get(task_projection, "task_id") ->
          :task

        Map.get(task_projection, :work_id) || Map.get(task_projection, "work_id") ->
          :work_request

        true ->
          :unknown
      end

    state = %{
      run_id: run_id,
      task: task_projection,
      phase_specs: phase_specs,
      current_phase: nil,
      completed: [],
      phase_statuses: %{},
      status: :ready,
      artifact_base: default_artifact_base(),
      plan_context: plan_context,
      source: source
    }

    Process.send_after(self(), :kickoff, 0)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    maybe_stop_shell_session(state)
    :ok
  end

  @impl true
  def handle_info(:kickoff, state) do
    case plan_context_error(state) do
      {:error, reason} ->
        Logger.warning(
          "RunExecutor plan context for #{state.run_id} rejected: #{inspect(reason)}"
        )

        _ = dispatch_task_execution_fail(state, {:plan_context_error, reason})
        finalize_terminal_and_stop(state, {:plan_context_error, reason})

      :ok ->
        case maybe_claim_task(state) do
          :ok ->
            case start_phase_at_index(state, 0) do
              {:ok, next_state} ->
                {:noreply, next_state}

              {:noop, next_state} ->
                {:noreply, next_state}

              {:error, reason} ->
                # `start_phase_at_index/2` already attempted
                # → `emit_phase_failure/4` → `emit_run_failure/2` → `run.fail`
                # before returning this error. If the run is still
                # non-terminal here it means the very first terminal
                # dispatch was rejected (transport, aggregate reject,
                # …) — re-route through the bounded retry helper so
                # the reason is not dropped on the floor.
                Logger.error(
                  "RunExecutor #{state.run_id} start_phase_at_index(0) failed: #{inspect(reason)}"
                )

                finalize_terminal_and_stop(state, {:initialization_failed, reason})
            end

          {:error, reason} ->
            Logger.warning("RunExecutor claim #{task_id(state)} failed: #{inspect(reason)}")

            _ = dispatch_task_execution_fail(state, {:claim_failure, reason})
            finalize_terminal_and_stop(state, {:claim_failure, reason})
        end
    end
  end

  @impl true
  def handle_info({:start_at, index}, state) do
    case start_phase_at_index(state, index) do
      {:ok, next_state} -> {:noreply, next_state}
      {:noop, next_state} -> {:noreply, next_state}
      {:error, reason} -> finalize_terminal_and_stop(state, {:phase_start_failed, index, reason})
    end
  end

  @impl true
  def handle_info({:retry_terminal_dispatch, reason, attempt_kind, attempt}, state) do
    case finalize_terminal_dispatch(state, reason, attempt_kind, attempt) do
      :ok -> {:stop, :normal, %{state | status: :failed}}
      :retry -> {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_cast({:advance_to, completed_index}, state) do
    completed = Enum.uniq(state.completed ++ [completed_index])
    next_index = completed_index + 1

    # Get the previous phase's terminal status from persisted state
    prev_status = Map.get(state.phase_statuses, completed_index, :in_progress)

    case Enum.at(state.phase_specs, next_index) do
      nil ->
        # All phases complete - finalize run
        Logger.info(
          "RunExecutor #{state.run_id} all #{length(state.phase_specs)} phases complete; finalizing"
        )

        next_state = %{state | completed: completed}

        case finalize_run(next_state) do
          {:ok, finalized_state} ->
            {:noreply, finalized_state}

          {:error, reason} ->
            Logger.error("RunExecutor #{state.run_id} finalize_run failed: #{inspect(reason)}")
            finalize_terminal_and_stop(next_state, {:finalize_run_failed, reason})
        end

      next_phase_spec ->
        next_step = phase_spec_name(next_phase_spec)

        # Use StepSequencer to determine if we should proceed based on prev phase status
        case StepSequencer.propagate_terminal(prev_status, next_step) do
          {:halt, :blocked} ->
            Logger.warning("Previous phase #{completed_index} blocked; halting sequence")
            next_state = %{state | completed: completed, status: :blocked}
            emit_phase_blocked(state, next_index, "blocked by previous phase")
            {:noreply, next_state}

          {:halt, :failed} ->
            Logger.warning("Previous phase #{completed_index} failed; halting sequence")
            {:noreply, %{state | completed: completed, status: :failed}}

          {:cont, _} ->
            # Proceed to next phase
            Process.send_after(self(), {:start_at, next_index}, 0)
            {:noreply, %{state | completed: completed}}
        end
    end
  end

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
         {:ok, worktree_record} <- maybe_create_worktree(state, phase_spec, phase_index) do
      # Retain the branch this phase wrote to so `finalize_run/1` can open a PR
      # from run state. `worktree_record` is otherwise phase-local (it is
      # cleaned up in the `after` below), which left AutoPR with no head branch
      # and no way to create a PR.
      state = remember_worktree(state, worktree_record)

      try do
        run_phase_body(state, phase_spec, index, phase_index, worktree_record)
      after
        cleanup_phase_worktree(state, phase_spec, phase_index, worktree_record)
      end
    else
      {:error, reason} = err ->
        case emit_phase_failure(state, phase_spec, phase_index, reason) do
          :ok -> err
          {:error, lifecycle_reason} -> {:error, lifecycle_reason}
        end
    end
  end

  # Records the most recent worktree so finalize_run/1 can derive the PR head
  # branch from Foreman's own state rather than depending on the agent printing
  # a FOREMAN_BRANCH marker into its artifact.
  defp remember_worktree(state, %{branch: branch} = record) when is_binary(branch) do
    Map.put(state, :last_worktree, %{
      branch: branch,
      base_ref: Map.get(record, :base_ref),
      worktree_path: Map.get(record, :worktree_path)
    })
  end

  defp remember_worktree(state, _record), do: state

  defp run_phase_body(state, phase_spec, index, phase_index, worktree_record) do
    case execute_with_worktree(state, phase_spec, index, phase_index, worktree_record) do
      {:ok, _next_state} = ok ->
        ok

      {:error, reason} = err ->
        case emit_phase_failure(state, phase_spec, phase_index, reason) do
          :ok -> err
          {:error, lifecycle_reason} -> {:error, lifecycle_reason}
        end
    end
  end

  defp execute_with_worktree(state, phase_spec, index, phase_index, worktree_record) do
    with {:ok, output} <- execute_agent(state, phase_spec, index, worktree_record),
         {:ok, artifact_path} <-
           __MODULE__.ArtifactTemplate.write(state, phase_spec, phase_index, output),
         {:ok, _required_file} <-
           enforce_required_file(state, phase_spec, phase_index, worktree_record),
         {:ok, artifact} <- __MODULE__.ArtifactTemplate.describe(artifact_path),
         {:ok, new_phase_statuses} <- emit_phase_complete(state, phase_index, artifact) do
      next_state = %{
        state
        | current_phase: index,
          status: :in_progress,
          phase_statuses: new_phase_statuses
      }

      GenServer.cast(self(), {:advance_to, index})
      {:ok, next_state}
    end
  end

  defp validate_phase_action(phase_spec, _phase_index) do
    case phase_action(phase_spec) do
      :command ->
        command = phase_value(phase_spec, :command)

        if is_binary(command) and command != "" do
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

  @default_activation_timeout_ms 30_000

  defp execute_agent(state, phase_spec, index, worktree_record) do
    phase_index = phase_number(phase_spec, index)
    request = build_request(state, phase_spec, phase_index, worktree_record)

    prompt =
      case phase_action(phase_spec) do
        :command -> render_command_template(phase_value(phase_spec, :command), state, phase_spec, index) || request.prompt
        _ -> request.prompt
      end

    task_type = phase_spec_name(phase_spec)
    policy = AgentRuntime.FailurePolicy.resolve(task_type, [])
    deadline_ms = System.system_time(:millisecond) + Map.fetch!(policy, :timeout_ms)

    # TRD-076: build idempotency key and acquire heartbeat lease so the
    # key stays `started` (or transitions `ambiguous` on expiry) regardless
    # of whether the agent completes, crashes, or hangs.
    # TRD-077: task_id and run_id are stored in KeyStore metadata so
    # CrashRecovery.has_no_side_effects? can look them up without parsing
    # the composite idempotency key string.
    workflow_prefix = workflow_prefix_for(state)
    idempotency_key = "#{workflow_prefix}-#{task_id(state)}-#{phase_index}"

    HeartbeatLease.acquire(
      idempotency_key,
      Map.fetch!(policy, :timeout_ms),
      task_id(state),
      state.run_id
    )

    HeartbeatLease.register_worker(state.run_id, state.run_id, idempotency_key)

    RunExecutorLiveness.record(state.run_id, self(), deadline_ms)

    try do
      # LGC-T002 / JHA-T002: dispatch through Overwatch.start_phase so the
      # supervised worker emits WorkerStarted/WorkerHeartbeat/WorkerExited
      # via CommandRouter. Without this, the run sits in awaiting_worker
      # forever (WorkerStarted is the only transition trigger).
      prompt_path = materialize_prompt(state, phase_index, prompt)
      provider = JidoHarness.request_provider(request)
      cwd = working_directory_for(state, worktree_record)
      env = foreman_env(state, worktree_record)
      remaining_ms = max(deadline_ms - System.system_time(:millisecond), 1_000)

      # Overwatch.build_launch_env assembles the env map from project_id +
      # opts[:env_map]. We pass our env there so the supervised worker
      # sees the same env the original AgentRuntime path did.
      launch_opts = [
        run_id: state.run_id,
        session_id: generate_session_id(),
        # Overridable so integration tests can inject an
        # Overwatch-worker-protocol test double (start_link/1 +
        # {:overwatch_activate,...} handshake + {:worker_result,...})
        # instead of spawning a real Jido.Harness agent session.
        # Defaults to the real production adapter everywhere this isn't
        # explicitly configured.
        adapter:
          Application.get_env(
            :foreman_server,
            :worker_adapter,
            ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
          ),
        adapter_name: "jido_harness",
        prompt_path: prompt_path,
        provider: provider,
        prompt: prompt,
        driver_opts: [
          timeout: remaining_ms,
          await_timeout: remaining_ms,
          cwd: cwd
        ],
        env_map: env,
        result_recipient: self(),
        activation_timeout_ms: @default_activation_timeout_ms,
        project_id: project_id(state)
      ]

      phase = Map.put(request, :phase_id, Identity.phase_id(state.run_id, phase_index))

      case Overwatch.start_phase(phase, launch_opts) do
        {:ok, %{worker_id: worker_id, launch_pid: launch_pid}} ->
          wait_for_worker_result(launch_pid, worker_id, state.run_id)

        {:error, {:already_started, _pid}} ->
          {:error, :worker_already_started}

        {:error, reason} ->
          {:error, {:overwatch_start_failed, reason}}
      end
    after
      # TRD-076: release the heartbeat lease on every exit path (normal
      # completion, crash, or error). The idempotency key transitions
      # `completed` in KeyStore so crash-recovery knows it can skip
      # side-effect inspection on retry.
      HeartbeatLease.release(idempotency_key)
      RunExecutorLiveness.clear(state.run_id, self())
    end
  end

  # Wait for the supervised worker to deliver its result. The worker pid
  # sends `{:worker_result, result}` before exiting; the launch_pid dies
  # normally after the worker exits. We accept either ordering: the
  # result message is the signal, the DOWN is just cleanup.
  @spec wait_for_worker_result(pid(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp wait_for_worker_result(launch_pid, worker_id, run_id) do
    ref = Process.monitor(launch_pid)

    result =
      receive do
        {:worker_result, result} ->
          result

        {:DOWN, ^ref, :process, ^launch_pid, _reason} ->
          {:error, :worker_died_no_result}
      after
        :timer.minutes(30) ->
          {:error, :worker_timeout}
      end

    # Remove the finished LaunchWorker so its `restart: :permanent`
    # DynamicSupervisor child spec (worker_supervisor.ex) doesn't relaunch
    # it and re-run this already-finished phase — a plain WorkerExited does
    # NOT seal the Worker aggregate (only WorkerCrashed/RunCompleted/
    # RunFailed do, see aggregates/worker.ex). `stop_worker/2` internally
    # blocks on `DynamicSupervisor.terminate_child/2`, which waits for
    # LaunchWorker's own `terminate/2` to finish; that callback can need to
    # round-trip through CommandRouter back to THIS run's aggregate actor —
    # i.e. back to this very process. Calling it synchronously here
    # deadlocks RunExecutor against itself (confirmed empirically: caused
    # ~300 cascading suite-wide failures once EventStore subscriptions
    # started timing out waiting on a stalled RunExecutor mailbox). Run it
    # in a detached task instead so it can't block this GenServer callback;
    # `LifecycleStore.claim_execution/1` (test doubles) plus this eventual
    # cleanup together close the re-launch gap without the deadlock risk.
    Task.start(fn -> Overwatch.WorkerSupervisor.stop_worker(worker_id, run_id) end)

    # Drain the DOWN if it hasn't arrived yet, so the process monitor
    # doesn't fire a stray message later.
    receive do
      {:DOWN, ^ref, :process, ^launch_pid, _reason} -> :ok
    after
      5_000 -> :ok
    end

    result
  end

  # Write the prompt to a deterministic path under the run's artifact
  # directory. WorkerStarted requires prompt_path as an @enforce_key,
  # but the Jido path keeps the prompt as a string — we materialize it
  # so the supervised worker (and any downstream tooling) can read it.
  # Same path on retries, so the file is overwritten, not duplicated.
  defp materialize_prompt(state, phase_index, prompt) do
    base = state.artifact_base || File.cwd!()
    path = Path.join([base, state.run_id, "phase-#{phase_index}-prompt.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, prompt)
    path
  end

  defp project_id(state) do
    Map.get(state.task, :project_id) || Map.get(state.task, "project_id")
  end

  defp generate_session_id do
    "session-" <> Elixir.EventStore.UUID.uuid4()
  end

  # Strip `-trd` suffix from workflow type so both `implement-trd` and
  # `implement-trd-beads` produce the same prefix (`implement`).
  defp workflow_prefix_for(state) do
    type =
      Map.get(state.task, :workflow_type) || Map.get(state.task, "workflow_type") ||
        Map.get(state.task, :workflow_name) || Map.get(state.task, "workflow_name") || "unknown"

    type |> to_string() |> String.replace(~r/-trd$/, "")
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
      case phase_template(phase_spec) do
        nil ->
          default_path(state, index)

        "" ->
          default_path(state, index)

        path when is_binary(path) ->
          expand(path, state)

        template when is_map(template) ->
          case template[:path] || template["path"] do
            nil -> default_path(state, index)
            "" -> default_path(state, index)
            path when is_binary(path) -> expand(path, state)
          end
      end
    end

    defp phase_template(phase_spec) do
      Map.get(phase_spec, :artifact_template) || Map.get(phase_spec, "artifact_template")
    end

    defp expand(path, state) do
      String.replace(path, "{run_id}", state.run_id)
      |> String.replace("{task_id}", task_id_of(state))
      |> String.replace("{run.id}", state.run_id)
      |> String.replace("{task.id}", task_id_of(state))
      |> String.replace("{task.projectReportsDir}", project_reports_dir(state))
      |> String.replace("{reportDir}", project_reports_dir(state))
    end

    defp project_reports_dir(state) do
      Path.join([working_directory_of(state), "docs", "reports", "foreman-#{task_id_of(state)}"])
    end

    defp working_directory_of(state) do
      case Map.get(state.task, :working_directory) || Map.get(state.task, "working_directory") ||
             Map.get(state.task, :source_repo_path) || Map.get(state.task, "source_repo_path") do
        dir when is_binary(dir) and dir != "" -> dir
        _ -> File.cwd!()
      end
    end

    defp default_path(state, index) do
      Path.join([state.artifact_base, state.run_id, "phase-#{index}.md"])
    end

    defp task_id_of(state) do
      Map.get(state.task, :task_id) || Map.get(state.task, "task_id") || "unknown"
    end
  end

  # Returns {:ok, new_phase_statuses} with the completion tracked.
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

    # Track phase completion in executor state for StepSequencer
    new_phase_statuses = Map.put(state.phase_statuses, phase_index, :completed)

    case dispatch_system(
           "phase.complete",
           payload,
           state.run_id,
           phase_id,
           "phase:#{state.run_id}:#{phase_id}"
         ) do
      {:ok, _} -> {:ok, new_phase_statuses}
      {:error, _} = err -> err
    end
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

    # A failed phase is a failed run: no later phase can satisfy the
    # workflow contract, and downstream consumers (projection,
    # task.retry, BootReconciliation) all key off `run.terminal?`.
    # Dispatch order matters: `run.fail` happens before the task-level
    # failure so the run flips terminal even if the task dispatch
    # surfaces a transport error — a nonterminal run blocks retry.
    # The Run aggregate's `reject_terminal_mutation` returns
    # `{:error, {:run_terminal, _}}` for an already-terminal run, so
    # this is idempotent w.r.t. supervisor reentry / duplicates.
    with {:ok, _} <-
           dispatch_system(
             "phase.fail",
             fail_payload,
             state.run_id,
             phase_id,
             "phase:#{state.run_id}:#{phase_id}"
           ),
         :ok <- emit_run_failure(state, reason),
         :ok <- maybe_fail_task(state, phase_spec, phase_index, reason) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "RunExecutor phase.fail dispatch for #{state.run_id}/#{phase_id} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Emit PhaseBlocked event for the next phase when the sequence halts due to blocked status.
  defp emit_phase_blocked(state, next_phase_index, reason) do
    phase_id = Identity.phase_id(state.run_id, next_phase_index)

    payload = %{
      run_id: state.run_id,
      phase_id: phase_id,
      index: next_phase_index,
      reason: reason
    }

    dispatch_system(
      "phase.block",
      payload,
      state.run_id,
      phase_id,
      "phase:#{state.run_id}:#{phase_id}"
    )
  end

  # Strict `run.fail` emission from `emit_phase_failure/4`:
  #   * `:ok` → aggregate accepted, run flipped terminal.
  #   * `{:error, {:run_terminal, _status}}` → already terminal from a
  #     prior supervisor / restart / BootReconciliation path; the
  #     terminal-fail invariant is satisfied, treat as success.
  #   * any other `{:error, reason}` (`:timeout`, dispatcher down,
  #     EventStore transport error, …) is propagated so the caller
  #     can surface a diagnostic. NOTE: `RunSupervisor` uses
  #     `restart: :transient`, so the executor's `:normal` exit
  #     after phase failure will NOT trigger an automatic restart;
  #     a propagated run-fail error keeps the diagnosis visible
  #     rather than silently logging it.
  defp emit_run_failure(state, reason) do
    case dispatch_run_fail(state, reason) do
      :ok ->
        :ok

      {:error, {:run_terminal, _status}} ->
        :ok

      {:error, dispatch_reason} ->
        {:error, {:run_fail_dispatch_deferred, dispatch_reason}}
    end
  end

  defp finalize_run(state) do
    Logger.info("RunExecutor #{state.run_id} finalize_run: maybe_complete_task")

    case maybe_complete_task(state) do
      :ok ->
        # Run auto-PR only after the task provider has confirmed completion.
        # gh must run from the repo root so it resolves the correct remote.
        context = %{
          run_id: state.run_id,
          base_branch: plan_base_branch(state),
          artifact_path: completion_artifact_path(state),
          head_branch: get_in(state, [:last_worktree, :branch]),
          cwd: working_directory(state.task)
        }

        Logger.info("RunExecutor #{state.run_id} finalize_run: attempting auto-pr")

        case AutoPR.maybe_create_pr(context) do
          :noop ->
            Logger.info(
              "RunExecutor #{state.run_id} finalize_run: no auto-pr (branch has no new commits)"
            )

          {:ok, pr_url} ->
            Logger.info("RunExecutor #{state.run_id} finalize_run: auto-pr created #{pr_url}")

          {:error, reason} ->
            # The run produced commits but no PR. Logging at warning previously
            # let this pass as a clean completion; surface it at error level so
            # the failure is attributable to the run.
            Logger.error(
              "RunExecutor #{state.run_id} finalize_run: auto-pr FAILED: #{inspect(reason)}"
            )
        end

        Logger.info("RunExecutor #{state.run_id} finalize_run: dispatch_run_complete")

        case dispatch_run_complete(state) do
          {:ok, _} ->
            Logger.info("RunExecutor #{state.run_id} finalize_run: dispatched run.complete")
            {:ok, %{state | status: :completed}}

          {:error, reason} = err ->
            Logger.error(
              "RunExecutor #{state.run_id} finalize_run: dispatch_run_complete returned: #{inspect(reason)}"
            )

            err
        end

      {:error, reason} = err ->
        Logger.error(
          "RunExecutor #{state.run_id} finalize_run: maybe_complete_task returned: #{inspect(reason)}"
        )

        err
    end
  end

  # Derive the PR base branch from plan_context["base_branch"], falling back to "main".
  defp plan_base_branch(state) do
    branch = Map.get(state.plan_context || %{}, "base_branch")
    if is_binary(branch) and branch != "", do: branch, else: "main"
  end

  defp build_request(state, phase_spec, index, worktree_record) do
    context = base_context(state, phase_spec, index, worktree_record)

    %{
      context: context,
      prompt: read_phase_prompt(state, phase_spec, index, context)
    }
  end

  defp read_phase_prompt(state, phase_spec, index, context) do
    content =
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

    render_prompt_template(content, state, phase_spec, index, context)
  end

  defp render_prompt_template(content, state, phase_spec, index, context) do
    assigns = prompt_template_assigns(state, phase_spec, index, context)

    result =
      content
      |> render_sections(assigns)

    Regex.replace(~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/, result, fn _match, key ->
      Map.get(assigns, key, "{{#{key}}}")
    end)
  end

  # Renders {{var}} placeholders inside a phase.command string with
  # shell-safe single-quote-escaped values. Variables come from the same
  # assigns map used by render_prompt_template/4 so manifests can reference
  # {{input.prompt}}, {{project_id}}, etc. in their command string.
  # Manifests that don't reference any variable still work (no-op).
  defp render_command_template(nil, _state, _phase_spec, _index), do: nil

  defp render_command_template(command, state, phase_spec, index)
       when is_binary(command) do
    assigns = prompt_template_assigns(state, phase_spec, index, %{})

    Regex.replace(~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/, command, fn _match, key ->
      case Map.get(assigns, key) do
        nil -> "''"
        value -> shell_quote(value)
      end
    end)
  end

  # Shell-safe single-quote wrapping: every embedded ' becomes '\''
  # (close-quote, escaped-quote, open-quote), the standard POSIX idiom.
  # The result is safe to interpolate into a shell command line under
  # any input, including values containing $, `, ;, &, |, etc.
  defp shell_quote(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\\''")
    "'" <> escaped <> "'"
  end

  defp shell_quote(value), do: shell_quote(to_string(value))

  # Strips {{#section KEY}}...{{/section}} blocks when KEY is empty.
  defp render_sections(content, assigns) do
    pattern = ~r"{{#section\s+([A-Za-z0-9_.-]+)}}(.*?){{/section}}"s

    Regex.replace(pattern, content, fn _match, key, inner ->
      case Map.get(assigns, key, "") do
        "" -> ""
        _ -> inner
      end
    end)
  end

  def prompt_template_assigns(state, phase_spec, index, context) do
    phase_index = prompt_phase_index(phase_spec, index)
    artifact_path = __MODULE__.ArtifactTemplate.path(state, phase_spec, phase_index)

    workflow_snapshot =
      Map.get(state.task, :workflow_snapshot) || Map.get(state.task, "workflow_snapshot") || %{}

    base =
      context
      |> Enum.map(fn {key, value} -> {to_string(key), render_template_value(value)} end)
      |> Map.new()

    Map.merge(base, %{
      "artifact_path" => artifact_path,
      "phase_index" => Integer.to_string(phase_index),
      "phase_name" => phase_spec_name(phase_spec),
      "project_id" => project_id(state),
      "run_id" => state.run_id,
      "task_id" => task_id(state),
      "workflow_digest" =>
        render_template_value(
          Map.get(workflow_snapshot, :workflow_digest) ||
            Map.get(workflow_snapshot, "workflow_digest") ||
            Map.get(state.task, :workflow_digest) || Map.get(state.task, "workflow_digest")
        ),
      "workflow_name" =>
        render_template_value(
          Map.get(workflow_snapshot, :workflow_name) ||
            Map.get(workflow_snapshot, "workflow_name") ||
            Map.get(state.task, :workflow_name) || Map.get(state.task, "workflow_name") ||
            Map.get(state.task, :workflow_type) || Map.get(state.task, "workflow_type")
        ),
      "input.prompt" => input_prompt(workflow_snapshot),
      "input.prompt_argument" => input_prompt_argument(workflow_snapshot)
    })
  end

  defp input_prompt(workflow_snapshot) do
    with {:ok, input} <- Map.fetch(workflow_snapshot, "input"),
         {:ok, prompt} <- Map.fetch(input, "prompt"),
         true <- is_binary(prompt) do
      prompt
    else
      _ -> ""
    end
  end

  defp input_prompt_argument(workflow_snapshot) do
    with {:ok, input} <- Map.fetch(workflow_snapshot, "input"),
         {:ok, prompt} <- Map.fetch(input, "prompt"),
         true <- is_binary(prompt) do
      Jason.encode!(prompt)
    else
      _ -> ""
    end
  end

  defp prompt_phase_index(phase_spec, index) when is_integer(index) and index >= 1 do
    case phase_value(phase_spec, :index) do
      value when is_integer(value) and value >= 1 -> value
      _ -> index
    end
  end

  defp prompt_phase_index(phase_spec, index), do: phase_number(phase_spec, index)

  defp render_template_value(nil), do: ""
  defp render_template_value(value) when is_binary(value), do: value
  defp render_template_value(value) when is_integer(value), do: Integer.to_string(value)
  defp render_template_value(value) when is_float(value), do: Float.to_string(value)
  defp render_template_value(value) when is_boolean(value), do: to_string(value)

  defp render_template_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value)
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

  defp base_context(state, phase_spec, index, worktree_record) do
    base = %{
      "phase_id" => Identity.phase_id(state.run_id, index),
      "run_id" => state.run_id,
      "task_id" => task_id(state),
      "working_directory" => working_directory_for(state, worktree_record)
    }

    base
    |> Map.merge(state.plan_context || %{})
    |> Map.merge(Map.get(phase_spec, :context) || Map.get(phase_spec, "context") || %{})
    |> override_working_directory(worktree_record)
  end

  # Per TRD Decision 9: when a worktree is active, its path is the
  # authoritative cwd; phase-level context must NOT override it. The
  # overlay merge above preserves all other phase context (script_key,
  # etc.); this final step only pins the worktree's path on top.
  defp override_working_directory(context, nil), do: context

  defp override_working_directory(context, %{worktree_path: path})
       when is_binary(path) and path != "" do
    Map.put(context, "working_directory", path)
  end

  defp working_directory_for(state, nil), do: working_directory(state.task)

  defp working_directory_for(_state, %{worktree_path: path}) when is_binary(path) and path != "",
    do: path

  defp working_directory(task) do
    case Map.get(task, :working_directory) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.fetch_env!("HOME")
    end
  end

  # ---------------------------------------------------------------------------
  # Worktree provisioning (TRD Decision 9 + Decisions 3 & 5)
  # ---------------------------------------------------------------------------
  #
  # When a phase declares a `worktree` block, RunExecutor provisions the
  # worktree before invoking the agent and cleans it up after the phase
  # is terminal. The worktree path is the authoritative cwd for the
  # agent; the frozen `source_revision` from the ImplementationContext is
  # the only acceptable `base` ref.
  # A `worktree` block is recognized when the phase spec carries a
  # `:worktree` (or "worktree") map. The block is honored when the
  # `enabled` field is not the literal `false`. Absence or `enabled: false`
  # both return `nil` so the phase runs unchanged.
  # The `worktree` block is opt-IN by explicit declaration but the PRD
  # contract ("Dispatch agents with git isolation: N agents running on N
  # worktrees, zero conflicts") is opt-OUT: every dispatch must isolate
  # its writes from the active checkout so the worker cannot race the
  # operator or other concurrent dispatches. Manifests that omit the
  # block get a default worktree off the current branch tip (HEAD) with
  # cleanup: always. Opting OUT is still explicit via `enabled: false`.
  defp maybe_create_worktree(state, phase_spec, phase_index) do
    case worktree_block(phase_spec) do
      %{enabled: false} ->
        {:ok, nil}

      nil ->
        create_default_worktree(state, phase_spec, phase_index)

      worktree when is_map(worktree) ->
        create_phase_worktree(state, phase_spec, phase_index, worktree)
    end
  end

  defp worktree_block(phase_spec) do
    case Map.get(phase_spec, :worktree) || Map.get(phase_spec, "worktree") do
      block when is_map(block) -> block
      _ -> nil
    end
  end

  defp create_phase_worktree(state, phase_spec, phase_index, worktree) do
    plan_context = state.plan_context || %{}

    with {:ok, project_root} <- fetch_string(plan_context, "project_root"),
         {:ok, source_revision} <- fetch_string(plan_context, "source_revision"),
         :ok <- assert_base_matches(worktree, source_revision, project_root),
         {:ok, implementation_key} <- fetch_string(plan_context, "implementation_key"),
         {:ok, project_id} <- fetch_project_id(state),
         :ok <- assert_trd_scope_prereqs(plan_context, implementation_key),
         phase_id = Identity.phase_id(state.run_id, phase_index),
         operation_id = "wt-" <> state.run_id <> "-" <> phase_id,
         slug = phase_slug(phase_spec),
         worktree_path = worktree_path_for(project_id, state.run_id, slug, worktree),
         :ok <- assert_worktree_path_contained(project_id, state.run_id, worktree_path),
         branch = render_worktree_template(branch_template(worktree), state, slug),
         :ok <- ensure_worktree_parent_dir(worktree_path),
         trd_scope = compute_trd_scope(plan_context, implementation_key) do
      Worktree.create(%{
        operation_id: operation_id,
        project_id: project_id,
        run_id: state.run_id,
        phase_id: phase_id,
        repo_path: project_root,
        worktree_path: worktree_path,
        base_ref: source_revision,
        branch: branch
      })
      |> case do
        {:ok, ^worktree_path} ->
          {:ok,
           %{
             operation_id: operation_id,
             worktree_path: worktree_path,
             branch: branch,
             base_ref: source_revision,
             project_root: project_root,
             project_id: project_id,
             implementation_key: implementation_key,
             trd_scope: trd_scope,
             cleanup: worktree_cleanup(worktree)
           }}

        {:ok, other_path} ->
          # Worktree.create guarantees the returned path matches the
          # requested path; treat drift as a hard failure rather than
          # passing a mismatched path downstream.
          _ = other_path
          {:error, {:worktree_path_drift, worktree_path, other_path}}

        {:error, _} = err ->
          err
      end
    end
  end

  # Default-on worktree for manifests without an explicit worktree block.
  # Enforces the PRD contract (git isolation per dispatch) without requiring
  # plan_context — derives project_root from the project projection's
  # registered path and resolves `base_ref` from `HEAD` (the current branch
  # tip). Skips TRD-specific assertions (base match against frozen
  # source_revision, implementation_key, trd_scope) because work-request and
  # non-plan flows don't have those values. The worktree is still pinned to
  # the current branch tip and cleaned up on terminal phases.
  defp create_default_worktree(state, phase_spec, phase_index) do
    with {:ok, project_id} <- fetch_project_id(state),
         {:ok, project_root} <- default_project_root(project_id, state),
         :ok <- assert_git_repo(project_root),
         {:ok, base_ref} <- resolve_revision(project_root, "HEAD"),
         phase_id = Identity.phase_id(state.run_id, phase_index),
         slug = phase_slug(phase_spec),
         operation_id = "wt-default-" <> state.run_id <> "-" <> phase_id,
         worktree_path = default_worktree_path_for(project_id, state.run_id, slug),
         :ok <- assert_worktree_path_contained(project_id, state.run_id, worktree_path),
         branch = "foreman/" <> state.run_id <> "/" <> slug,
         :ok <- ensure_worktree_parent_dir(worktree_path) do
      Worktree.create(%{
        operation_id: operation_id,
        project_id: project_id,
        run_id: state.run_id,
        phase_id: phase_id,
        repo_path: project_root,
        worktree_path: worktree_path,
        base_ref: base_ref,
        branch: branch
      })
      |> case do
        {:ok, ^worktree_path} ->
          {:ok,
           %{
             operation_id: operation_id,
             worktree_path: worktree_path,
             branch: branch,
             base_ref: base_ref,
             project_root: project_root,
             project_id: project_id,
             implementation_key: nil,
             trd_scope: nil,
             cleanup: :always
           }}

        {:ok, other_path} ->
          _ = other_path
          {:error, {:worktree_path_drift, worktree_path, other_path}}

        {:error, _} = err ->
          err
      end
    end
  end

  # Default-on worktrees use the slug as the leaf directory (no template
  # rendering) so the path is deterministic and trivially auditable from
  # the run_id alone.
  defp default_worktree_path_for(project_id, run_id, slug) do
    Path.join([worktree_base_root(), project_id, run_id, slug])
  end

  # Resolve the project_root for default-on worktrees. Prefers
  # `state.task.working_directory` (set for plan tasks) and falls back to
  # the project's registered path on disk (set for work requests via
  # `foreman project create --path ...`).
  defp default_project_root(project_id, state) do
    home = System.fetch_env!("HOME")
    project_root = working_directory(state.task)

    case project_root do
      dir when is_binary(dir) and dir != "" and dir != home ->
        {:ok, dir}

      _ ->
        case ProjectionStore.project_projection(project_id) do
          %{path: path} when is_binary(path) and path != "" ->
            {:ok, path}

          nil ->
            {:error, :project_not_found}

          _ ->
            {:error, :project_path_missing}
        end
    end
  end

  # Confirm project_root is a git working tree before resolving HEAD
  # against it. `git rev-parse --verify HEAD^{commit}` returns
  # :unresolvable_revision for a non-repo directory.
  defp assert_git_repo(project_root) do
    case System.cmd("git", ["-C", project_root, "rev-parse", "--git-dir"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      _ -> {:error, {:not_a_git_repo, project_root}}
    end
  end

  # Per TRD Decision 10, the Beads workflow requires `trd_path` to be frozen
  # in plan_context so `TRD_SCOPE` can be derived deterministically. If
  # `BEADS_DB` is set but `trd_path` is missing or `implementation_key` is
  # not a full hex SHA, fail closed at provisioning rather than exporting
  # an empty scope that the skill cannot defend against.
  defp assert_trd_scope_prereqs(plan_context, implementation_key) do
    cond do
      beads_db_path(plan_context) in [nil, ""] ->
        :ok

      trd_path(plan_context) in [nil, ""] ->
        {:error, {:plan_context_missing, "trd_path"}}

      not valid_hex?(implementation_key) ->
        {:error, {:plan_context_missing, "implementation_key"}}

      true ->
        :ok
    end
  end

  defp compute_trd_scope(plan_context, implementation_key) do
    case beads_db_path(plan_context) do
      path when is_binary(path) and path != "" ->
        slug = trd_slug(plan_context)
        key_prefix = String.slice(implementation_key, 0, 12)
        slug <> "-" <> key_prefix

      _ ->
        nil
    end
  end

  defp trd_slug(plan_context) do
    plan_context
    |> trd_path()
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
    |> sanitize_slug()
  end

  # Canonical slug alphabet for shell-safe, bead-title-safe scope tags:
  # `[a-z0-9-]` only. Operators who name TRDs with uppercase letters,
  # spaces, dots, or underscores get those folded to `-`. The slug is a
  # human-readable scope tag, not an identity claim; the upstream
  # `implementation_key` is the binding identity.
  defp sanitize_slug(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp sanitize_slug(_), do: ""

  defp trd_path(plan_context) do
    Map.get(plan_context, "trd_path") || Map.get(plan_context, :trd_path) || ""
  end

  defp valid_hex?(value) when is_binary(value) do
    String.match?(value, ~r/\A[0-9a-fA-F]{64}\z/)
  end

  defp valid_hex?(_), do: false

  defp assert_base_matches(worktree, source_revision, project_root) do
    case Map.get(worktree, :base) || Map.get(worktree, "base") do
      nil ->
        :ok

      declared when is_binary(declared) and declared != "" ->
        case resolve_revision(project_root, declared) do
          {:ok, ^source_revision} ->
            :ok

          {:ok, other_sha} ->
            {:error, {:worktree_base_mismatch, declared, other_sha, source_revision}}

          {:error, reason} ->
            {:error, {:worktree_base_unresolvable, declared, reason}}
        end

      _ ->
        :ok
    end
  end

  # Resolve a branch name, tag, or SHA to the commit SHA it points at.
  # `git rev-parse --verify <ref>^{commit}` exits non-zero for refs that
  # do not exist in the repository, returning the resolved commit for
  # branches, tags, and SHAs alike.
  defp resolve_revision(repo_path, ref) do
    args = ["-C", repo_path, "rev-parse", "--verify", "#{ref}^{commit}"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {sha, 0} when is_binary(sha) ->
        normalized = sha |> String.trim() |> String.downcase()
        if normalized == "", do: {:error, :empty_revision}, else: {:ok, normalized}

      {_output, _code} ->
        # Fall back to accepting the literal as a SHA when git can't
        # dereference it (e.g. shallow clone). Equality with the frozen
        # revision still enforces the TRD invariant.
        trimmed = String.trim(ref)

        if String.match?(trimmed, ~r/^[0-9a-f]{7,64}$/),
          do: {:ok, String.downcase(trimmed)},
          else: {:error, :unresolvable_revision}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:plan_context_missing, key}}
    end
  end

  defp fetch_project_id(state) do
    pid = project_id(state)

    if pid == "" do
      {:error, :project_id_missing}
    else
      {:ok, pid}
    end
  end

  defp phase_slug(phase_spec) do
    case phase_spec_name(phase_spec) do
      nil ->
        "phase"

      "" ->
        "phase"

      name when is_atom(name) ->
        name |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")

      name when is_binary(name) ->
        if name == "", do: "phase", else: String.replace(name, ~r/[^A-Za-z0-9_.-]/, "-")
    end
  end

  defp worktree_path_for(project_id, run_id, slug, worktree) do
    template = Map.get(worktree, :path) || Map.get(worktree, "path") || slug
    rendered = render_worktree_template(template, %{run_id: run_id}, slug)
    Path.join([worktree_base_root(), project_id, run_id, rendered])
  end

  defp worktree_base_root do
    Path.join([System.user_home!(), ".foreman", "worktrees"])
  end

  defp branch_template(worktree) do
    Map.get(worktree, :branch) || Map.get(worktree, "branch") || "foreman/{run_id}/{phase}"
  end

  defp worktree_cleanup(worktree) do
    case Map.get(worktree, :cleanup) || Map.get(worktree, "cleanup") do
      "never" -> :never
      _ -> :always
    end
  end

  defp render_worktree_template(template, state, slug) do
    run_id = Map.get(state, :run_id) || Map.get(state, "run_id") || ""

    template
    |> String.replace("{run_id}", run_id)
    |> String.replace("{phase}", slug)
  end

  # Containment check: the rendered worktree path MUST resolve to a
  # location under `~/.foreman/worktrees/<project_id>/<run_id>/`. This
  # guards against template payloads that smuggle `..` segments through
  # placeholders or that render to absolute paths.
  defp assert_worktree_path_contained(project_id, run_id, worktree_path) do
    expected_root =
      Path.join([worktree_base_root(), project_id, run_id])
      |> Path.expand()

    actual_root = Path.expand(worktree_path)

    if String.starts_with?(actual_root, expected_root <> "/") or actual_root == expected_root do
      :ok
    else
      {:error, {:worktree_path_escape, expected_root, actual_root}}
    end
  end

  defp ensure_worktree_parent_dir(worktree_path) do
    parent = Path.dirname(worktree_path)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} -> {:error, {:worktree_parent_mkdir_failed, parent, reason}}
    end
  end

  # Cleanup runs in the `after` clause of `run_single_phase/3` so any
  # terminal path (success, agent error, artifact error, enforcement
  # error) still cleans. `cleanup: never` is honored by short-circuiting.
  defp cleanup_phase_worktree(_state, _phase_spec, _phase_index, :no_worktree), do: :ok

  defp cleanup_phase_worktree(_state, _phase_spec, _phase_index, nil), do: :ok

  defp cleanup_phase_worktree(_state, _phase_spec, _phase_index, %{cleanup: :never}), do: :ok

  defp cleanup_phase_worktree(state, phase_spec, phase_index, worktree_record) do
    phase_id = Identity.phase_id(state.run_id, phase_index)

    _ = unbind_vfs(state.run_id)

    Worktree.clean(%{
      operation_id: worktree_record.operation_id,
      project_id: worktree_record.project_id,
      run_id: state.run_id,
      phase_id: phase_id,
      repo_path: worktree_record.project_root
    })
    |> case do
      :ok ->
        :ok

      {:ok, :already_cleaned} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RunExecutor #{state.run_id}/#{phase_id} worktree cleanup reported: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Env injection (TRD Decision 9). Every phase gets the shell-session
  # export so the common non-worktree path can still bind to the
  # executor-owned shell lifecycle. Worktree-managed phases add the
  # remaining Foreman worktree markers below.
  defp foreman_env(state, nil), do: maybe_put_shell_session_env(%{}, state)

  defp foreman_env(state, worktree_record) do
    plan_context = state.plan_context || %{}
    implementation_key = worktree_record.implementation_key || ""

    _ = bind_vfs(state.run_id, worktree_record.worktree_path)

    base_env =
      %{
        "FOREMAN_WORKTREE" => "1",
        "FOREMAN_RUN_ID" => state.run_id,
        "FOREMAN_WORKTREE_PATH" => worktree_record.worktree_path,
        "FOREMAN_EXPECTED_BRANCH" => worktree_record.branch,
        "FOREMAN_SOURCE_REVISION" => worktree_record.base_ref,
        "FOREMAN_IMPLEMENTATION_KEY" => implementation_key
      }
      |> maybe_put_shell_session_env(state)

    case beads_db_path(plan_context) do
      nil ->
        base_env

      "" ->
        base_env

      path ->
        # Per TRD Decision 10, every Beads phase MUST export `TRD_SCOPE`
        # alongside `BEADS_DB`. The scope is computed at provisioning by
        # `create_phase_worktree/4` and stamped on the worktree record;
        # if it is absent here, frozen-context validation must have
        # been bypassed — refuse to launch the adapter.
        case worktree_record.trd_scope do
          scope when is_binary(scope) and scope != "" ->
            base_env
            |> Map.put("BEADS_DB", path)
            |> Map.put("TRD_SCOPE", scope)

          other ->
            raise ArgumentError,
                  "missing TRD_SCOPE on worktree record " <>
                    "(beads_db_path=#{inspect(path)}, trd_scope=#{inspect(other)})"
        end
    end
  end

  defp maybe_put_shell_session_env(env, state) do
    case ensure_shell_session_id(state) do
      {:ok, session_id} when is_binary(session_id) and session_id != "" ->
        Map.put(env, "FOREMAN_SHELL_SESSION_ID", session_id)

      _ ->
        env
    end
  end

  # Per TRD Decision 10, `TRD_SCOPE` is exported alongside `BEADS_DB`. The
  # value is computed at provisioning by `create_phase_worktree/4` and
  # stamped on the worktree record; see `compute_trd_scope/2` for the
  # derivation.

  defp beads_db_path(plan_context) do
    Map.get(plan_context, "beads_database_path") ||
      Map.get(plan_context, :beads_database_path)
  end

  defp task_id(state) do
    Map.get(state.task, :task_id) || Map.get(state.task, "task_id") ||
      Map.get(state.task, :id) || Map.get(state.task, "id") || ""
  end

  defp ensure_shell_session_id(%{run_id: run_id}) do
    case Process.get({__MODULE__, :shell_session_id, run_id}) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      _ ->
        case ForemanServer.Agents.JidoShellRunner.start_session("run-executor", owner: self()) do
          {:ok, session_id} ->
            Process.put({__MODULE__, :shell_session_id, run_id}, session_id)
            {:ok, session_id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp maybe_stop_shell_session(%{run_id: run_id}) do
    _ = unbind_vfs(run_id)

    case Process.delete({__MODULE__, :shell_session_id, run_id}) do
      session_id when is_binary(session_id) and session_id != "" ->
        _ = ForemanServer.Agents.JidoShellRunner.stop_session(session_id)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_stop_shell_session(_state), do: :ok

  # TRD-2026-4212be7e JSH-T003 / TRD-034 — VFS isolation per worktree.
  # Bind `run_id` to its worktree root so the shell session rejects
  # commands outside the worktree. Use `bind_with_check` so the
  # configured allowlist (`config :foreman_server, :jido_vfs`) is
  # enforced; if the worktree is outside the allowlist we log and
  # continue without binding (fail-open at the env layer — the shell
  # session itself still enforces isolation via JidoShellRunner's
  # in-memory VFS mount).
  defp bind_vfs(run_id, worktree_path)
       when is_binary(run_id) and run_id != "" and is_binary(worktree_path) and
              worktree_path != "" do
    case Process.whereis(VfsIsolation) do
      nil ->
        _ =
          Logger.debug("RunExecutor #{run_id}: VfsIsolation GenServer not running; skipping bind")

        :ok

      _pid ->
        case VfsIsolation.bind_with_check(run_id, worktree_path) do
          :ok ->
            :ok

          {:error, :worktree_not_in_allowed_list} ->
            Logger.warning(
              "RunExecutor #{run_id}: VFS bind refused for #{worktree_path} (outside allowlist)"
            )

            :ok
        end
    end
  end

  defp bind_vfs(_run_id, _worktree_path), do: :ok

  # Symmetric to `bind_vfs/2`. Idempotent — calling `unbind/1` on an
  # unbound run_id is a no-op in VfsIsolation. Failures from the
  # GenServer (e.g. noproc during shutdown) are swallowed because
  # unbinding is best-effort cleanup.
  defp unbind_vfs(run_id) when is_binary(run_id) and run_id != "" do
    case Process.whereis(VfsIsolation) do
      nil -> :ok
      _pid -> _ = VfsIsolation.unbind(run_id)
    end

    :ok
  end

  defp unbind_vfs(_run_id), do: :ok

  # Test-only exports. Avoid calling these from production code.
  @doc false
  def __bind_vfs_for_test__(run_id, worktree_path), do: bind_vfs(run_id, worktree_path)

  @doc false
  def __unbind_vfs_for_test__(run_id), do: unbind_vfs(run_id)
  # Provider-facing identifier for the task. When the task projection
  # carries an `external_id` (the provider's identifier, e.g. the Beads
  # issue id `foreman-zuk0`), use that — adapters translate it directly
  # into `br update --claim <id>` and other provider-specific commands.
  # Falls back to `task_id` for tasks that were never linked to a
  # provider issue (e.g. tests that bypass the import path).
  defp provider_task_id(state) do
    case Map.get(state.task, :external_id) || Map.get(state.task, "external_id") do
      nil -> task_id(state)
      "" -> task_id(state)
      id -> id
    end
  end

  defp project_id(state) do
    Map.get(state.task, :project_id) || Map.get(state.task, "project_id") || ""
  end

  # Phase specs reach the executor via the persisted workflow_snapshot,
  # which `Approval.prepare/1` canonicalizes to string keys (see the
  # `render_strict_fields` contract in `command_gateway.ex`). The
  # `TaskApproved` event is JSON-encoded for EventStore persistence, so
  # on replay the snapshot is fully string-keyed AND atom-valued
  # fields like `action: :command` come back as the binary "command".
  # A few atom keys (`:action`, `:phase_id`, `:index`) survive the
  # in-process `Catalog.resolve_workflow/3` atomization for callers
  # that build the snapshot from memory. Use `phase_value/2` to read
  # either shape (atom- or string-keyed map) so the validation and
  # execution paths cannot drift across the two. `Map.fetch` is
  # preferred to `||` so a phase value of `false` (or any other non-nil
  # falsy) is preserved instead of silently falling through to the
  # alternate key. Values are returned untouched — never coerced to
  # atoms — because user-defined command strings can legitimately
  # collide with atoms that happen to be loaded by the runtime.
  defp phase_value(phase_spec, key) when is_atom(key) do
    case Map.fetch(phase_spec, key) do
      {:ok, value} -> value
      :error -> Map.get(phase_spec, Atom.to_string(key))
    end
  end

  # The `action` field is closed: only `:command` and `:bash` are
  # meaningful. After a JSON round-trip the value comes back as the
  # binary "command" or "bash" instead of the atom; remap those two
  # to their atom twins so downstream `case` matches keep working.
  # Any other binary (or atom) is preserved unchanged — including
  # unexpected or malformed values — so `validate_phase_action/2`'s
  # fall-through clause handles them by its current default of
  # `{:ok, :ok}`. Tightening that to reject unknown actions is a
  # separate concern and out of scope for this snapshot-shape fix.
  defp phase_action(phase_spec) do
    case phase_value(phase_spec, :action) do
      "command" -> :command
      "bash" -> :bash
      other -> other
    end
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

  # For work-sourced runs there is no task to claim — skip the callback entirely.
  defp maybe_claim_task(state) do
    if state.source == :work_request do
      :ok
    else
      case provider_enabled?(project_id(state)) do
        true ->
          claim(project_id(state), provider_task_id(state), task_provider_actor())
          |> to_lifecycle_result()

        false ->
          :ok
      end
    end
  end

  # For work-sourced runs: no TaskProvider callback, dispatch directly to WorkRequest.
  defp maybe_complete_task(state) do
    if state.source == :work_request do
      dispatch_work_execution_complete(state)
    else
      case provider_enabled?(project_id(state)) do
        true ->
          case complete(
                 project_id(state),
                 provider_task_id(state),
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
  end

  # For work-sourced runs: no TaskProvider callback, dispatch directly to WorkRequest.
  defp maybe_fail_task(state, phase_spec, index, reason) do
    if state.source == :work_request do
      dispatch_work_execution_fail(state, reason)
    else
      case provider_enabled?(project_id(state)) do
        true ->
          failure_reason =
            merge_failure_reason(reason, %{
              artifact_path: ArtifactTemplate.path(state, phase_spec, index)
            })

          case fail(project_id(state), provider_task_id(state), state.run_id, failure_reason) do
            {:ok, _issue} -> dispatch_task_execution_fail(state, reason)
            {:error, failure_reason} -> {:error, failure_reason}
          end

        false ->
          dispatch_task_execution_fail(state, reason)
      end
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

  # WorkRequest aggregate dispatchers — used when state.source == :work_request.
  defp dispatch_work_execution_complete(state) do
    work_id = work_id(state)

    dispatch_system_command(
      "work.execution_complete",
      Identity.task_complete_command_id(state.run_id),
      "work:#{work_id}",
      %{work_id: work_id, run_id: state.run_id}
    )
    |> to_dispatch_result()
  end

  defp dispatch_work_execution_fail(state, reason) do
    work_id = work_id(state)

    dispatch_system_command(
      "work.execution_fail",
      Identity.task_fail_command_id(state.run_id),
      "work:#{work_id}",
      %{work_id: work_id, run_id: state.run_id, reason: inspect(reason)}
    )
    |> to_dispatch_result()
  end

  defp work_id(state) do
    Map.get(state.task, :work_id) || Map.get(state.task, "work_id") ||
      raise("work_id unavailable in RunExecutor state — expected source=:work_request")
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

  defp dispatch_run_fail(state, reason) do
    case consume_dispatch_injection(:run_fail) do
      {:error, _} = err ->
        err

      :passthrough ->
        dispatch_system_command(
          "run.fail",
          Identity.run_fail_command_id(state.run_id),
          "run:#{state.run_id}",
          %{run_id: state.run_id, reason: inspect(reason)}
        )
        |> to_dispatch_result()
    end
  end

  # -- run.fail retry helper ----------------------------------------------
  #
  # The `run.fail` dispatch is the load-bearing terminal invariant: a
  # non-terminal run blocks `task.retry`, holds `worker_status` in a
  # blocked state, and prevents downstream consumers (projection,
  # BootReconciliation) from reconciling the task. When `run.fail`
  # itself fails (transport, dispatcher down, aggregate reject) the
  # executor MUST NOT silently `:stop, :normal` — that path drops the
  # reason on the floor and leaves the run non-terminal until the
  # StuckDetector's 15-min idle threshold fires.
  #
  # This helper implements a fast bounded retry followed by an indefinite
  # slow retry:
  #
  #   * Fast budget: up to `@max_terminal_dispatch_attempts` attempts with
  #     exponential backoff capped at `@terminal_dispatch_backoff_cap_ms`
  #     (a few seconds total). This covers transient dispatcher blips
  #     without holding the run open longer than the original timeout.
  #   * Slow loop: on fast-budget exhaustion, schedule another attempt
  #     every `@terminal_dispatch_slow_interval_ms`. The executor STAYS
  #     ALIVE — no abnormal exit, no supervisor restart, no impact on
  #     other runs. The slow loop terminates when either `run.fail`
  #     finally succeeds, or the run is already terminal via a parallel
  #     safety net (StuckDetector's `run.flag_stuck` at 15-min idle
  #     makes our next `run.fail` return `{:error, :run_terminal}`,
  #     which we treat as success and stop normally).
  #
  # This design deliberately avoids exiting `:abnormal` because the
  # supervisor's `max_restarts/max_seconds` budget is shared across every
  # active run; a single dispatch loop in one run could exhaust the
  # budget and drop every other executor. Keeping the executor alive
  # during the slow loop isolates the impact to the affected run only.
  @max_terminal_dispatch_attempts 5
  @terminal_dispatch_backoff_base_ms 250
  @terminal_dispatch_backoff_cap_ms 2_000
  @terminal_dispatch_slow_interval_ms 60_000

  # Returns `:ok` when the executor may stop normally, or `:retry` when
  # the helper has scheduled another attempt and the executor must stay
  # alive (`{:noreply, ...}`).
  defp finalize_terminal_dispatch(state, reason) do
    finalize_terminal_dispatch(state, reason, :fast, 1)
  end

  defp finalize_terminal_dispatch(state, reason, attempt_kind, attempt) do
    case dispatch_run_fail(state, reason) do
      :ok ->
        Logger.info(
          "RunExecutor #{state.run_id} terminal dispatch succeeded (#{attempt_kind} attempt #{attempt})"
        )

        :ok

      {:error, {:run_terminal, _status}} ->
        Logger.info(
          "RunExecutor #{state.run_id} terminal dispatch: run already terminal " <>
            "(#{attempt_kind} attempt #{attempt})"
        )

        :ok

      {:error, dispatch_reason} ->
        {backoff_ms, next_kind} = next_terminal_dispatch_step(attempt_kind, attempt)

        Logger.warning(
          "RunExecutor #{state.run_id} terminal dispatch #{attempt_kind} attempt #{attempt} " <>
            "failed: #{inspect(dispatch_reason)}; retrying in #{backoff_ms}ms as #{next_kind}"
        )

        Process.send_after(
          self(),
          {:retry_terminal_dispatch, reason, next_kind, attempt + 1},
          backoff_ms
        )

        :retry
    end
  end

  defp next_terminal_dispatch_step(:fast, attempt)
       when attempt >= @max_terminal_dispatch_attempts do
    {@terminal_dispatch_slow_interval_ms, :slow}
  end

  defp next_terminal_dispatch_step(:fast, attempt) do
    backoff_ms =
      @terminal_dispatch_backoff_base_ms
      |> Kernel.*(:math.pow(2, attempt - 1))
      |> min(@terminal_dispatch_backoff_cap_ms)
      |> trunc()

    {backoff_ms, :fast}
  end

  defp next_terminal_dispatch_step(:slow, _attempt) do
    {@terminal_dispatch_slow_interval_ms, :slow}
  end

  # Centralizes the `:stop, :normal` after a `run.fail` dispatch so the
  # five silent-stop paths in this module cannot drop a reason on the floor.
  defp finalize_terminal_and_stop(state, reason) do
    case finalize_terminal_dispatch(state, reason) do
      :ok -> {:stop, :normal, %{state | status: :failed}}
      :retry -> {:noreply, %{state | status: :failed}}
    end
  end

  # Test seam: a counter-driven function that decides whether to inject
  # a `{:error, reason}` into the next `run.fail` dispatch. Production
  # code reads the env at every call so a test can set the hook
  # immediately before the run starts and clear it (or let it fall
  # through to `:passthrough`) on the second attempt.
  #
  # Function shape: `(attempt_count) -> :passthrough | {:error, reason}`.
  defp consume_dispatch_injection(:run_fail) do
    case Application.get_env(:foreman_server, :run_executor_test_dispatch_failure) do
      nil ->
        :passthrough

      fun when is_function(fun, 1) ->
        count = bump_dispatch_injection_count()
        fun.(count)

      _ ->
        :passthrough
    end
  end

  defp bump_dispatch_injection_count do
    current = Application.get_env(:foreman_server, :run_executor_test_dispatch_attempt_count, 0)
    next = current + 1
    Application.put_env(:foreman_server, :run_executor_test_dispatch_attempt_count, next)
    next
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
    with {:ok, base} <- fetch_plan_base(task_projection),
         {:ok, enriched} <- merge_implementation_context(base, task_projection) do
      {:ok, enriched}
    else
      {:not_applicable, _} = na -> na
      {:error, _} = err -> err
    end
  end

  defp fetch_plan_base(task_projection) do
    case ForemanServer.Workflow.PlanContext.build(task_projection) do
      {:ok, ctx} -> {:ok, ctx}
      {:not_applicable, _} = na -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  # The frozen ImplementationContext is computed at task approval by
  # `CommandGateway.freeze_implementation_context/2` and persisted under
  # `workflow_snapshot["implementation"]`. Re-running
  # `ImplementationContext.build/1` at execution time would re-resolve
  # the source revision and could observe a different commit than the
  # one that was approved. We therefore copy the payload verbatim from
  # the snapshot.
  defp merge_implementation_context(base, task_projection) do
    case implementation_payload_from_snapshot(task_projection) do
      nil ->
        {:ok, base}

      payload when is_map(payload) ->
        {:ok, Map.merge(base, stringify_keys(payload))}

      _ ->
        {:ok, base}
    end
  end

  # `enforce_required_file` and downstream phase adapters look up flat
  # `requiredFile: trd_path`-style keys as strings. The frozen
  # implementation payload carried in `workflow_snapshot["implementation"]`
  # arrives with atom keys; normalize to strings at the merge boundary so
  # flat-context gates resolve atomically without forcing every caller
  # to dual-key Map.get. Existing plan-task keys (`planning.prd_path` etc.)
  # already arrive as strings from `PlanContext.build`, so this only
  defp stringify_keys(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string(k), v} end)
  end

  defp implementation_payload_from_snapshot(task_projection) do
    snapshot =
      Map.get(task_projection, :workflow_snapshot) ||
        Map.get(task_projection, "workflow_snapshot") || %{}

    cond do
      is_map(snapshot) and is_map(Map.get(snapshot, "implementation")) ->
        Map.get(snapshot, "implementation")

      is_map(snapshot) and is_map(Map.get(snapshot, :implementation)) ->
        Map.get(snapshot, :implementation)

      true ->
        nil
    end
  end

  defp plan_context_error(state) do
    case Map.get(state.plan_context || %{}, :__plan_context_error__) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp enforce_required_file(state, phase_spec, phase_index, worktree_record) do
    case Map.get(phase_spec, :required_file) do
      nil ->
        {:ok, :no_gate}

      "" ->
        {:error, {:required_file_blank, phase_index}}

      key when is_binary(key) ->
        case resolve_context_key(state, key, phase_index) do
          {:ok, path} ->
            absolute_path = resolve_gate_path(path, state, worktree_record)

            if is_binary(absolute_path) and File.regular?(absolute_path) do
              {:ok, absolute_path}
            else
              {:error, {:required_file_missing, key, absolute_path}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:required_file_invalid, phase_index}}
    end
  end

  # `requiredFile` paths live in the same working directory the agent
  # executed in: the phase worktree when one is active, otherwise the
  # project's working directory. Relative paths resolve against that
  # root so `File.regular?/1` checks the file the agent actually had
  # access to, not the daemon's cwd. Absolute paths pass through.
  defp resolve_gate_path(path, state, worktree_record) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(working_directory_for(state, worktree_record), path)
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
