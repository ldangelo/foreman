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
  alias ForemanServer.Idempotency.HeartbeatLease
  alias ForemanServer.RunExecutorLiveness
  alias ForemanServer.Identity
  alias ForemanServer.Overwatch
  alias ForemanServer.PrAssociate
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.CommitDeferral
  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Workflow.PhasePR
  alias ForemanServer.Workflow.PhaseSpec
  alias ForemanServer.Workflow.PlanContext
  # Without this alias `StepSequencer.propagate_terminal/2` resolves to a
  # non-existent top-level module and every multi-phase run — `plan.yaml`
  # included — crashed the executor on the phase 1 -> phase 2 transition
  # instead of advancing. Compile emitted the warning; nothing failed on it.
  alias ForemanServer.Workflow.StepSequencer
  alias ForemanServer.Workflow.WorktreeSpec
  alias ForemanServer.Agents.VfsIsolation
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.Workflow.Worktree
  alias ForemanServer.WorkerEnvironment
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

  def claim(project_id, task_id, actor),
    do: claim(project_id, task_id, actor, nil)

  @spec claim(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def claim(project_id, task_id, actor, run_id)
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" do
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :claim, run_id),
         result <- provider_module.claim(task_id, actor, project_config) do
      maybe_retry_lost_claim(result, provider_module, project_config, task_id)
    end
  end

  def claim(_project_id, _task_id, _actor, _run_id), do: {:error, :invalid_claim}

  @spec complete(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def complete(project_id, task_id, run_id, artifact_path)
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" and
             is_binary(run_id) and run_id != "" do
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :close, run_id) do
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
    with {:ok, provider_module, project_config} <- resolve_provider(project_id, :reopen, run_id) do
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
  # JSON-decoded string keys only, because the resolved phase is frozen onto a
  # domain event and round-trips through JSON.
  #
  # Accept either convention here and normalize once, so every downstream read
  # is a plain atom lookup (AGENTS.md §5.4). Previously each consumer
  # compensated with `Map.get(spec, :k) || Map.get(spec, "k")`.
  defp extract_phase_specs(task) do
    snapshot =
      Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

    case Map.get(snapshot, :phases) || Map.get(snapshot, "phases") do
      phases when is_list(phases) -> PhaseSpec.normalize_all(phases)
      _ -> []
    end
  end

  # The workflow's `worktree:` block, read from the same frozen
  # `workflow_snapshot` the phases come from. It is a WORKFLOW-level key beside
  # `name:` and `phases:` — a run has one worktree, so there is nothing for a
  # phase to declare about it (see `WorktreeSpec`). `nil` means the workflow
  # declared no block and every default applies.
  defp extract_worktree_spec(task) do
    snapshot =
      Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

    WorktreeSpec.normalize(Map.get(snapshot, :worktree) || Map.get(snapshot, "worktree"))
  end

  @impl true
  def init({run_id, task_projection}) do
    phase_specs = extract_phase_specs(task_projection)

    plan_context =
      case plan_context_for(task_projection) do
        {:ok, ctx} -> ctx
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
      worktree_spec: extract_worktree_spec(task_projection),
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

              # The phase provisioned a worktree and then failed. Finalize with
              # THAT state, not the pre-phase one, or `cleanup_run_worktree/2`
              # cannot see the checkout it is supposed to reclaim.
              {:error, reason, phase_state} ->
                Logger.error(
                  "RunExecutor #{state.run_id} start_phase_at_index(0) failed: #{inspect(reason)}"
                )

                finalize_terminal_and_stop(phase_state, {:initialization_failed, reason})
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
      {:ok, next_state} ->
        {:noreply, next_state}

      {:noop, next_state} ->
        {:noreply, next_state}

      {:error, reason} ->
        finalize_terminal_and_stop(state, {:phase_start_failed, index, reason})

      # Worktree-bearing state from a failed phase — see `run_single_phase/3`.
      {:error, reason, phase_state} ->
        finalize_terminal_and_stop(phase_state, {:phase_start_failed, index, reason})
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
            # A halt is terminal for the worktree even though it dispatches no
            # terminal command here. Cleanup used to happen at every phase
            # boundary, so a halt still reclaimed disk; now that it is
            # run-terminal, these two branches are the only run endings that
            # reach neither `finalize_run/1` nor `finalize_terminal_and_stop/2`,
            # and `cleanup: always` would silently not apply to them.
            _ = cleanup_run_worktree(next_state, :failure)
            {:noreply, next_state}

          {:halt, :failed} ->
            Logger.warning("Previous phase #{completed_index} failed; halting sequence")
            next_state = %{state | completed: completed, status: :failed}
            _ = cleanup_run_worktree(next_state, :failure)
            {:noreply, next_state}

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
    # Read the checkout's branch before the first phase can move anything, so
    # `finalize_run/1` knows which branch the run's work was cut from.
    state = remember_run_base_branch(state)

    with {:ok, _} <- validate_phase_action(phase_spec, phase_index),
         {:ok, _} <- emit_phase_start(state, phase_spec, phase_index),
         {:ok, worktree_record} <- maybe_create_worktree(state, phase_index) do
      # The run's worktree, and the branch it writes to, are run-level facts:
      # `remember_run_worktree/2` makes the record reusable by every later phase
      # and `remember_worktree/2` retains the branch so `finalize_run/1` can
      # open a PR from run state.
      #
      # There is deliberately no per-phase cleanup here. The worktree belongs to
      # the run, so tearing it down at a phase boundary would destroy the very
      # checkout the next phase is meant to continue in. Disk is reclaimed once,
      # by `cleanup_run_worktree/2` in `finalize_run/1`, and by the `RunDeleted`
      # fan-out (`Worktree.clean_for_run/1`) for runs that end some other way.
      state =
        state
        |> remember_run_worktree(worktree_record)
        |> remember_worktree(worktree_record)

      # The worktree record lives ONLY in this local `state` until the phase
      # succeeds and `run_phase_body/5` hands it back. A failing phase body used
      # to return a bare `{:error, reason}`, so the callers in `handle_info/2`
      # fell back to their PRE-phase state and `cleanup_run_worktree/2` looked
      # for a `:run_worktree` that state had never seen — leaving the checkout on
      # disk for a run that declared `cleanup: always`. Carry the state out with
      # the error so the declared policy applies to the failure path too.
      case run_phase_body(state, phase_spec, index, phase_index, worktree_record) do
        {:error, reason} -> {:error, reason, state}
        other -> other
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

  # Retains the run's worktree record so every later phase reuses the same
  # checkout instead of provisioning its own. Latched on key presence: the
  # first worktree-enabled phase provisions, the rest reuse. A phase that opted
  # out (`enabled: false`, record `nil`) must not clear a worktree an earlier
  # phase established, so only a real record is stored.
  defp remember_run_worktree(state, %{worktree_path: path} = record)
       when is_binary(path) and path != "" do
    Map.put_new(state, :run_worktree, record)
  end

  defp remember_run_worktree(state, _record), do: state

  # The PR base branch is the branch the run's work was cut from, recorded once
  # when the FIRST phase starts and never re-read.
  #
  # It is read from `vcs_working_directory/1` — the checkout AutoPR later runs
  # `git rev-list`, `git push`, and `gh pr create` in, so `--base` is
  # interpreted against the same repository the name came from — at the same
  # moment `phase_lineage_base_ref/2` resolves phase 1's `base_ref` from `HEAD`
  # of that checkout. Branch name and base commit therefore describe one state
  # of the repository.
  #
  # Resolving it at finalize time instead would answer "whichever branch the
  # operator has checked out now", which is not what the run was cut from. And
  # phase 1's `base_ref` cannot answer it alone: it is a commit SHA, while
  # `gh pr create --base` takes a branch name.
  #
  # Latched on key presence rather than phase index, because the value is a
  # run-level fact and later phases must not re-read a checkout the operator
  # may have switched. It deliberately does not hang off `remember_worktree/2`:
  # a phase declaring `worktree: enabled: false` provisions no worktree, yet
  # such a run can still land a PR through the `FOREMAN_BRANCH` override.
  defp remember_run_base_branch(state) do
    if Map.has_key?(state, :run_base_branch) do
      state
    else
      Map.put(state, :run_base_branch, checkout_branch(vcs_working_directory(state)))
    end
  end

  # `git symbolic-ref --quiet --short HEAD` names the checked-out branch and
  # exits non-zero on a detached HEAD. `rev-parse --abbrev-ref HEAD` would
  # instead print the literal `HEAD` there, which `gh pr create --base` accepts
  # as a ref name — a wrong PR target that reads as a resolved answer.
  defp checkout_branch(repo_path) do
    args = ["-C", repo_path, "symbolic-ref", "--quiet", "--short", "HEAD"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        # `--quiet` prints nothing when HEAD is simply not a symbolic ref, so
        # empty output is a detached checkout and anything else is git's own
        # complaint (directory missing, not a repository).
        case String.trim(output) do
          "" -> {:error, {:checkout_branch_unresolvable, repo_path, :detached_head}}
          detail -> {:error, {:checkout_branch_unresolvable, repo_path, detail}}
        end
    end
  end

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
         # `enforce_required_file/4` returns the state carrying whatever the
         # gate captured, so a discovered planning document survives into the
         # next phase's context.
         {:ok, state} <-
           enforce_required_file(state, phase_spec, phase_index, worktree_record),
         {:ok, _} <- commit_phase_worktree(state, phase_spec, phase_index, worktree_record),
         :ok <-
           maybe_record_phase_pr(state, phase_spec, phase_index, worktree_record, artifact_path),
         {:ok, artifact} <- __MODULE__.ArtifactTemplate.describe(artifact_path),
         {:ok, new_phase_statuses} <- emit_phase_complete(state, phase_index, artifact) do
      next_state = %{
        state
        | current_phase: index,
          status: :in_progress,
          completed: Enum.uniq((state.completed || []) ++ [index]),
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

    payload =
      %{
        run_id: state.run_id,
        phase_id: phase_id,
        index: phase_index,
        name: Map.get(phase_spec, :name),
        attempt: 1,
        artifact_template: Map.get(phase_spec, :artifact_template) || %{}
      }
      |> Map.merge(
        ForemanServer.Workflow.StallPolicy.payload_fields(Map.get(phase_spec, :stall_detection))
      )

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

    case assert_plan_subject(state, phase_spec, phase_index) do
      :ok -> dispatch_agent(state, phase_spec, index, phase_index, worktree_record)
      {:error, _} = err -> err
    end
  end

  # A phase whose output is DISCOVERED rather than named must have been told
  # what to write about, or discovery captures a document on whatever
  # subject the agent inferred from the repository and the run reports
  # success for an irrelevant deliverable. Three consecutive live runs
  # (run-d6cdefe6…, run-dda35390…, run-3da49f9e…) produced a PRD about the
  # same unrelated topic from three different task descriptions, which the
  # old filename gate caught only by accident.
  #
  # The check is on `plan_subject_env/1` — the single expression that puts
  # `FOREMAN_TASK_TITLE` into the dispatched env — so "asserted" and
  # "delivered" are the same value, not two computations that can drift. It
  # runs before the heartbeat lease so a subject-less phase never launches a
  # worker at all.
  defp assert_plan_subject(state, phase_spec, phase_index) do
    key = Map.get(phase_spec, :required_file)

    cond do
      PlanContext.document_dir(key) == nil -> :ok
      Map.has_key?(plan_subject_env(state), "FOREMAN_TASK_TITLE") -> :ok
      true -> {:error, {:plan_subject_missing, phase_index, key}}
    end
  end

  defp dispatch_agent(state, phase_spec, index, phase_index, worktree_record) do
    request = build_request(state, phase_spec, phase_index, worktree_record)

    prompt =
      case phase_action(phase_spec) do
        :command ->
          render_command_template(phase_value(phase_spec, :command), state, phase_spec, index) ||
            request.prompt

        _ ->
          request.prompt
      end

    task_type = phase_spec_name(phase_spec)
    policy = AgentRuntime.FailurePolicy.resolve(task_type, phase_timeout_opts(phase_spec))
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

      model =
        case Map.get(phase_spec, :models) do
          nil ->
            nil

          %{"default" => m} when is_binary(m) ->
            m

          %{default: m} when is_binary(m) ->
            m

          %{} = models ->
            v = Map.get(models, :default) || Map.get(models, "default")
            if is_binary(v), do: v, else: nil

          _ ->
            nil
        end

      env =
        foreman_env(state, worktree_record, artifact_path_for(state, phase_spec, index), model)

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
        driver_opts:
          [
            timeout: remaining_ms,
            await_timeout: remaining_ms,
            cwd: cwd
          ]
          |> maybe_put_driver_model(model),
        project_id: project_id(state),
        env_map: env,
        result_recipient: self(),
        activation_timeout_ms: @default_activation_timeout_ms,
        secrets:
          WorkerEnvironment.extract_secrets(WorkerEnvironment.build_env_map(project_id(state)))
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

    # Remove the LaunchWorker child spec so nothing for this phase can be
    # relaunched — a plain WorkerExited does NOT seal the Worker aggregate
    # (only WorkerCrashed/RunCompleted/RunFailed do, see
    # aggregates/worker.ex), so a crashed worker would otherwise keep
    # restarting for a phase this process has already finished with.
    #
    # This is cleanup, NOT the guard against relaunching a *finished* phase.
    # It used to be that guard, and it lost: under the old
    # `restart: :permanent` child spec every worker exit relaunched, and in
    # run-de055c18749db5e9c702d24950268cf9 the relaunch beat this task by
    # 56ms and leaked an agent that ran 8m42s past the run's terminal state.
    # `LaunchWorker` now propagates its worker's exit reason to a
    # `restart: :transient` child spec, so a finished or torn-down worker
    # ends its child without depending on this race.
    #
    # `stop_worker/2` internally blocks on
    # `DynamicSupervisor.terminate_child/2`, which waits for LaunchWorker's
    # shutdown to finish; that can need to round-trip through CommandRouter
    # back to THIS run's aggregate actor — i.e. back to this very process.
    # Calling it synchronously here deadlocks RunExecutor against itself
    # (confirmed empirically: caused ~300 cascading suite-wide failures once
    # EventStore subscriptions started timing out waiting on a stalled
    # RunExecutor mailbox). Run it in a detached task instead so it can't
    # block this GenServer callback.
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
      Map.get(phase_spec, :artifact_template)
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
        Logger.info("RunExecutor #{state.run_id} finalize_run: attempting auto-pr")

        case maybe_auto_pr(state) do
          :noop ->
            Logger.info(
              "RunExecutor #{state.run_id} finalize_run: no auto-pr (branch has no new commits)"
            )

          {:ok, pr_url} ->
            Logger.info("RunExecutor #{state.run_id} finalize_run: auto-pr created #{pr_url}")
            record_pr_association(state.run_id, pr_url)

          {:error, reason} ->
            # The run produced commits but no PR. Logging at warning previously
            # let this pass as a clean completion; surface it at error level so
            # the failure is attributable to the run.
            Logger.error(
              "RunExecutor #{state.run_id} finalize_run: auto-pr FAILED: #{inspect(reason)}"
            )
        end

        # After AutoPR, never before: the worktree is the checkout AutoPR pushes
        # from. Reclaiming it earlier is what the old per-phase `after` clause
        # did, and it deleted the work before anything could propose it.
        _ = cleanup_run_worktree(state, :success)

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

  # AutoPR's `{:ok, pr_url}` used to be logged and dropped here, so a PR could
  # exist on GitHub while every read model denied it:
  # run-776527010ea5d3568b742adbd25ab872 opened
  # https://github.com/ldangelo/foreman/pull/420, yet its run stream held
  # exactly RunStarted then RunCompleted and `GET /api/runs/<id>` reported no
  # PR at all. Appending `PrAssociated` is the only thing that puts the URL on
  # the run projection (see `ProjectionStore`'s "PrAssociated" clause).
  #
  # A store failure cannot be repaired from here and must not fail the run: the
  # PR is already open and the work did succeed. The event log is the only
  # durable channel for the URL, so when appending fails the URL survives in
  # this log line alone — hence `error`, with the URL spelled out so an
  # operator can re-associate it by hand.
  defp record_pr_association(run_id, pr_url) do
    case PrAssociate.store(run_id, pr_url) do
      {:ok, ^run_id} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RunExecutor #{run_id} finalize_run: PR #{pr_url} created but NOT recorded " <>
            "on the run read model: #{inspect(reason)}"
        )
    end
  end

  defp maybe_auto_pr(state) do
    if phase_pr_created_or_reused?(state.run_id) do
      Logger.info(
        "RunExecutor #{state.run_id} finalize_run: skipping final auto-pr because phase PR records exist"
      )

      :noop
    else
      auto_pr(state)
    end
  end

  defp maybe_record_phase_pr(state, phase_spec, phase_index, worktree_record, artifact_path) do
    if Map.get(phase_spec, :stack_pr) == true do
      request_phase_pr(state, phase_spec, phase_index, worktree_record, artifact_path)
    else
      :ok
    end
  end

  defp request_phase_pr(state, phase_spec, phase_index, %{worktree_path: cwd}, artifact_path)
       when is_binary(cwd) and cwd != "" do
    phase_id = Identity.phase_id(state.run_id, phase_index)

    if phase_pr_recorded_for_phase?(state.run_id, phase_id) do
      :ok
    else
      with {:ok, base_branch} <- run_base_branch(state),
           {:ok, head_branch} <- run_head_branch(state),
           {:ok, record} <-
             PhasePR.maybe_create(%PhasePR.Request{
               run_id: state.run_id,
               phase_id: phase_id,
               phase_index: phase_index,
               phase_name: phase_spec_name(phase_spec),
               base_branch: base_branch,
               head_branch: head_branch,
               cwd: cwd,
               artifact_path: artifact_path,
               existing_records: phase_pr_records(state.run_id)
             }) do
        record_phase_pr(record)
      else
        {:error, %PhasePR.Error{} = error} ->
          {:error, {:phase_pr_failed, error.reason, error.details}}

        {:error, reason} ->
          {:error, {:phase_pr_failed, reason}}
      end
    end
  end

  defp request_phase_pr(_state, _phase_spec, phase_index, worktree_record, _artifact_path) do
    {:error, {:phase_pr_worktree_unresolved, phase_index, worktree_record}}
  end

  defp run_head_branch(state) do
    case get_in(state, [:last_worktree, :branch]) do
      branch when is_binary(branch) and branch != "" -> {:ok, branch}
      _ -> {:error, :phase_pr_head_branch_unresolved}
    end
  end

  defp record_phase_pr(%PhasePR.Record{} = record) do
    payload = Map.from_struct(record)

    case dispatch_system(
           "phase_pr.record",
           payload,
           record.run_id,
           record.phase_id,
           "phase_pr:#{record.run_id}:#{record.phase_id}"
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:phase_pr_record_failed, reason}}
    end
  end

  defp phase_pr_created_or_reused?(run_id) do
    run_id
    |> phase_pr_records()
    |> Enum.any?(&(Map.get(&1, :status) in ["created", "existing", :created, :existing]))
  end

  defp phase_pr_recorded_for_phase?(run_id, phase_id) do
    run_id
    |> phase_pr_records()
    |> Enum.any?(fn record ->
      Map.get(record, :phase_id) == phase_id and
        Map.get(record, :status) in ["created", "existing", :created, :existing]
    end)
  end

  defp phase_pr_records(run_id) do
    case ProjectionStore.run(run_id) do
      %{phase_prs: phase_prs} when is_list(phase_prs) -> phase_prs
      _ -> []
    end
  end

  # Auto-PR for a finished run. The base branch is resolved BEFORE anything is
  # pushed: with no base there is no defensible PR to open.
  #
  # `gh` must run from the repo root so it resolves the correct remote — which
  # is also the checkout `run_base_branch/1` took the base branch name from.
  defp auto_pr(state) do
    case run_base_branch(state) do
      {:ok, base_branch} ->
        AutoPR.maybe_create_pr(%{
          run_id: state.run_id,
          base_branch: base_branch,
          artifact_path: completion_artifact_path(state),
          head_branch: get_in(state, [:last_worktree, :branch]),
          cwd: vcs_working_directory(state)
        })

      {:error, reason} ->
        {:error, {:auto_pr_base_branch_unresolved, reason}}
    end
  end

  # The branch a PR must target, or the typed reason Foreman cannot name it.
  #
  # This used to read `plan_context["base_branch"]` and fall back to `"main"`.
  # Nothing writes that key: `PlanContext.build/1` does not produce it, and the
  # `base_branch` argument `work.submit` accepts is captured at the protocol
  # level only (`Mcp.Tools`) and projected into nothing the executor reads. So
  # every run targeted `main`. run-776527010ea5d3568b742adbd25ab872 was cut from
  # `feat/mcp-run-details` and opened PR #420 against `main`, whose diff was an
  # entire unrelated session of commits instead of the two documents the run
  # produced. The default is what made that wrong answer look plausible
  # (AGENTS.md 5.2), so there is no longer one.
  #
  # `:run_base_branch_unrecorded` is the ABSENT case — no phase ever started, so
  # nothing read the checkout — kept distinct from the malformed case
  # `checkout_branch/1` reports (AGENTS.md 5.3).
  defp run_base_branch(state) do
    case Map.get(state, :run_base_branch) do
      {:ok, branch} -> {:ok, branch}
      {:error, _reason} = err -> err
      nil -> {:error, {:run_base_branch_unrecorded, state.run_id}}
    end
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
      case Map.get(phase_spec, :prompt_path) do
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
    |> Map.merge(Map.get(phase_spec, :context) || %{})
    |> map_from_models(phase_spec)
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

  # Inject workflow-declared model into context (Req-020).
  # phase_spec.models is %{"default" => "MiniMax"} from YAML,
  # normalized to atom-keyed map by PhaseSpec.normalize/1.
  defp map_from_models(context, spec) do
    case Map.get(spec, :models) do
      nil ->
        context

      %{"default" => model} when is_binary(model) ->
        Map.put(context, :model, model)

      %{default: model} when is_binary(model) ->
        Map.put(context, :model, model)

      %{} = models ->
        # Could be string or atom keys; find the default
        model = Map.get(models, "default") || Map.get(models, :default)
        if is_binary(model), do: Map.put(context, :model, model), else: context

      _ ->
        context
    end
  end

  # The phase's working directory: the worktree when the phase provisioned
  # one, otherwise the project root the frozen plan context resolved. Plan
  # runs already advertise that root to the agent in the phase context JSON
  # (`base_context/4` merges `plan_context` over the base), so the cwd the
  # agent is launched in — and every path resolved against it — must agree
  # with it. `working_directory/1` alone answers $HOME here: no projection
  # populates `task.working_directory`.
  defp working_directory_for(state, nil) do
    case state.plan_context do
      %{"working_directory" => dir} when is_binary(dir) and dir != "" -> dir
      _ -> working_directory(state.task)
    end
  end

  defp working_directory_for(_state, %{worktree_path: path}) when is_binary(path) and path != "",
    do: path

  defp working_directory(task) do
    case Map.get(task, :working_directory) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.fetch_env!("HOME")
    end
  end

  # Working directory for git/gh at finalize time.
  #
  # `working_directory/1` falls back to $HOME when the task carries no
  # directory, which is the case for `work.submit` runs (they have no task).
  # $HOME is not a git repository, so AutoPR failed with
  # "fatal: not a git repository" — a plausible-looking default that is wrong
  # for every VCS operation.
  #
  # Resolution order: the frozen plan context (task-approved runs), then the
  # registered project's own path (work.submit runs, whose PlanContext.build
  # returns :not_applicable and therefore carries no project_root), then the
  # task directory.
  defp vcs_working_directory(state) do
    case state.plan_context do
      %{"project_root" => root} when is_binary(root) and root != "" ->
        root

      _ ->
        project_path(state) || working_directory(state.task)
    end
  end

  defp project_path(state) do
    with id when is_binary(id) and id != "" <- project_id(state),
         %{} = projection <- ProjectionStore.project_projection(id),
         path when is_binary(path) and path != "" <-
           Map.get(projection, :path) || Map.get(projection, "path") do
      path
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Worktree provisioning — ONE worktree per RUN, declared per WORKFLOW
  # ---------------------------------------------------------------------------
  #
  # A run gets exactly one worktree, provisioned by its first phase and reused
  # unchanged by every phase after it. The whole workflow executes in that
  # single checkout on a single branch, so a later phase sees its predecessors'
  # files directly rather than inheriting them through a chain of per-phase
  # branches.
  #
  # The declaration is therefore WORKFLOW-level: `state.worktree_spec` comes
  # from the manifest's top-level `worktree:` key (see `WorktreeSpec`), not from
  # a phase. `enabled: false` opts the whole workflow out and provisions
  # nothing.
  #
  # This replaced a per-phase design on both axes. Each phase used to create its
  # own worktree directory and branch, cut from the previous phase's branch tip,
  # destroyed at the phase boundary — a strictly worse way to express "the
  # artifacts flow forward", needing the predecessor's branch to outlive its
  # worktree, leaving N branches per run for AutoPR to pick the last of, and
  # tearing down state at every boundary that never needed tearing down. And
  # each phase used to carry its own `worktree:` block, which for a run-scoped
  # resource meant N declarations could contradict each other while only the
  # first could be honored.
  #
  # Worse, the phase-level block selected between two non-interchangeable
  # provisioning functions: declaring it routed the run through one that
  # required an ImplementationContext, so `worktree: {enabled: true}` on a
  # plan-type workflow did not restate the default — it failed the run. There is
  # now ONE provisioning path (`create_run_worktree/2`) and the block is legal on
  # every workflow; whether the frozen `source_revision` pins the base is a
  # property of the RUN (does it carry an ImplementationContext), never of the
  # declaration.
  defp maybe_create_worktree(state, phase_index) do
    case state.worktree_spec do
      %{enabled: false} ->
        {:ok, nil}

      _ ->
        ensure_run_worktree(state, phase_index)
    end
  end

  # Reuse before create. `state.run_worktree` is written by
  # `remember_run_worktree/2` when the run's worktree is provisioned and
  # survives every later phase in the executor's state.
  defp ensure_run_worktree(state, phase_index) do
    case Map.get(state, :run_worktree) do
      %{worktree_path: path} = record when is_binary(path) and path != "" ->
        reuse_run_worktree(record, path)

      nil ->
        create_run_worktree(state, phase_index)
    end
  end

  # A reused worktree carries one per-phase value: `base_ref`, refreshed to the
  # shared checkout's current HEAD. That is what keeps the discovery gate
  # honest across phases — `capture_planning_document/4` diffs
  # `<base_ref>..HEAD` for documents NEW IN THE PHASE, and `commit_phase_worktree/4`
  # commits at each phase boundary, so HEAD at phase N's start is exactly
  # "everything phases 1..N-1 produced". Phase 1's PRD is therefore correctly
  # not a candidate in phase 2.
  #
  # A phase declaring `commit: false` DOES now reach a discovery-gated phase
  # with its work still pending — the load-time guard that forbade it,
  # `Interpreter.validate_commit_deferral!/2`'s `requiredFile` clause (that
  # function is now `validate_commit_cleanup!/3`, and carries no such clause), was
  # deleted deliberately, because forbidding it also forbade the phase batching
  # the `commit:` tag exists to provide. When that happens HEAD has not moved,
  # so the predecessor's uncommitted document IS a candidate for the successor's
  # gate. That is a property of discovery's scope, not a manifest defect, and it
  # is the operator's stated intent: phases that batch into one commit are one
  # unit of work. Do not re-add a load-time veto here.
  #
  # A worktree that has vanished mid-run is a hard failure (AGENTS.md 5.2/5.3):
  # continuing would run the phase against whatever directory git resolves
  # instead, and produce a plausible-looking artifact from the wrong tree.
  defp reuse_run_worktree(record, path) do
    if File.dir?(path) do
      case resolve_revision(path, "HEAD") do
        {:ok, head} -> {:ok, %{record | base_ref: head}}
        {:error, reason} -> {:error, {:run_worktree_head_unresolvable, path, reason}}
      end
    else
      {:error, {:run_worktree_vanished, path}}
    end
  end

  # The single provisioning path. It takes no phase and no phase-level block:
  # everything declarable comes from `state.worktree_spec` (the workflow's
  # top-level `worktree:`), and everything derived comes from the run.
  #
  # `project_root` and `base_ref` are resolved by whether the RUN carries an
  # ImplementationContext, not by whether a block was declared:
  #
  #   * With one (`implement-trd*`), the root and the base are the frozen
  #     `project_root`/`source_revision` from plan context, a declared `base:`
  #     must resolve to that same revision (`assert_base_matches/3`, TRD
  #     Decisions 3/5), and `implementation_key`/`trd_scope` are carried on the
  #     record for `TRD_SCOPE`/`BEADS_DB` export.
  #   * Without one (`plan`, `prd`, `fix`, ad-hoc work), the root is the
  #     project's registered path and the base is that checkout's `HEAD`. A
  #     declared `base:` is resolved against the project root and used as-is.
  #
  # That split is why the two former functions could be merged: they differed
  # only in where those two values came from, never in what a manifest was
  # allowed to say.
  defp create_run_worktree(state, phase_index) do
    spec = state.worktree_spec || %{}

    with {:ok, project_id} <- fetch_project_id(state),
         {:ok, project_root, base_ref, implementation_key, trd_scope} <-
           resolve_run_base(state, spec),
         {:ok, cleanup} <- worktree_cleanup(spec),
         phase_id = Identity.phase_id(state.run_id, phase_index),
         operation_id = "wt-" <> state.run_id,
         worktree_path = run_worktree_path(project_id, state.run_id, spec),
         :ok <- assert_worktree_path_contained(project_id, state.run_id, worktree_path),
         branch = render_worktree_template(branch_template(spec), state),
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
             implementation_key: implementation_key,
             trd_scope: trd_scope,
             cleanup: cleanup
           }}

        {:ok, other_path} ->
          # Worktree.create guarantees the returned path matches the requested
          # path; treat drift as a hard failure rather than passing a mismatched
          # path downstream.
          {:error, {:worktree_path_drift, worktree_path, other_path}}

        {:error, _} = err ->
          err
      end
    end
  end

  # An ImplementationContext is detected by the presence of the values it
  # freezes, not by the workflow name, so a run either has all of them or is
  # treated as having none. A partially-populated plan context is a hard error
  # rather than a silent fall back to the project checkout, because pinning an
  # implementation run to `HEAD` instead of its frozen revision is exactly the
  # plausible-looking wrong answer AGENTS.md 5.2 forbids.
  defp resolve_run_base(state, spec) do
    plan_context = state.plan_context || %{}

    case fetch_string(plan_context, "source_revision") do
      {:ok, source_revision} ->
        with {:ok, project_root} <- fetch_string(plan_context, "project_root"),
             :ok <- assert_base_matches(spec, source_revision, project_root),
             {:ok, implementation_key} <- fetch_string(plan_context, "implementation_key"),
             :ok <- assert_trd_scope_prereqs(plan_context, implementation_key) do
          {:ok, project_root, source_revision, implementation_key,
           compute_trd_scope(plan_context, implementation_key)}
        end

      {:error, _} ->
        with {:ok, project_id} <- fetch_project_id(state),
             {:ok, project_root} <- default_project_root(project_id, state),
             :ok <- assert_git_repo(project_root),
             {:ok, base_ref} <- resolve_declared_base(spec, project_root) do
          {:ok, project_root, base_ref, nil, nil}
        end
    end
  end

  defp resolve_declared_base(spec, project_root) do
    case Map.get(spec, :base) do
      declared when is_binary(declared) and declared != "" ->
        case resolve_revision(project_root, declared) do
          {:ok, sha} -> {:ok, sha}
          {:error, reason} -> {:error, {:worktree_base_unresolvable, declared, reason}}
        end

      _ ->
        resolve_revision(project_root, "HEAD")
    end
  end

  # The run's single worktree lives at one leaf directory under
  # `~/.foreman/worktrees/<project_id>/<run_id>/`, so the path is deterministic
  # and trivially auditable from the run_id alone. The workflow may name that
  # leaf with `worktree: path:`; the default is `workspace`.
  #
  # This replaced `default_worktree_path_for/3` and `worktree_path_for/4`, which
  # appended a per-phase slug because each phase had its own worktree. Along with
  # them went `phase_lineage_base_ref/2`, which resolved a phase's base by
  # looking up the PREVIOUS phase's branch tip so committed artifacts would flow
  # forward. With one worktree per run there is no predecessor to chain from and
  # nothing to flow between: later phases open the same checkout on the same
  # branch and read their inputs as ordinary files. The "documents new in THIS
  # phase" property the chained base existed to preserve is now supplied by
  # `reuse_run_worktree/2`, which refreshes `base_ref` to the shared checkout's
  # HEAD at each phase start.
  defp run_worktree_path(project_id, run_id, spec) do
    leaf =
      case Map.get(spec, :path) do
        path when is_binary(path) and path != "" -> render_worktree_template(path, run_id)
        _ -> "workspace"
      end

    Path.join([worktree_base_root(), project_id, run_id, leaf])
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
    case Map.get(worktree, :base) do
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
    case project_id(state) do
      nil -> {:error, :project_id_missing}
      "" -> {:error, :project_id_missing}
      pid when is_binary(pid) -> {:ok, pid}
      pid -> {:error, {:project_id_malformed, pid}}
    end
  end

  defp worktree_base_root do
    Path.join([System.user_home!(), ".foreman", "worktrees"])
  end

  # The run's branch. The workflow may name it with `worktree: branch:`; the
  # default is `foreman/{task_id}/{run_id}`.
  #
  # The default used to be `foreman/{run_id}/{phase}` and then
  # `foreman/{run_id}`. The former named a per-phase branch that no longer
  # exists; the latter was stable but operator-hostile because run ids are long
  # hashes. `{task_id}` renders the provider-facing task id when available, then
  # falls back to Foreman's task/work ids and finally the run id for ad-hoc
  # legacy projections.
  #
  # `{run_id}` is always included so retrying the same task (same task_id,
  # different run_id) produces a unique branch and does not collide with the
  # retained worktree of a failed run using `cleanup: never`.
  defp branch_template(spec) do
    case Map.get(spec, :branch) do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> "foreman/{task_id}/{run_id}"
    end
  end

  # Whether the run's worktree directory is removed once the run finalizes.
  # Declared per manifest as `cleanup: always | never` inside a `worktree:`
  # block.
  #
  # The default is `never`. `:always` was too aggressive: it deleted the
  # checkout at the phase boundary, so a document the agent had written but not
  # committed vanished before anything could propose it, leaving AutoPR with
  # zero commits.
  #
  # An in-flight attempt at that fix instead read a NEW `:clean_worktree` key
  # and stopped reading `:cleanup` at all. That silently orphaned the
  # `cleanup: never` already declared by `implement-trd.yaml` and
  # `implement-trd-beads.yaml` — the declaration kept parsing, kept appearing in
  # the manifest, and controlled nothing. It only escaped notice because the new
  # default happened to agree with it. `:cleanup` is the manifest key; there is
  # no second spelling (AGENTS.md 5.4).
  #
  # `clean_worktree` is NOT a manifest key and never was: it is the
  # `VcsAdapter` operation name for removing a worktree
  # (`VcsAdapter.Default.clean_worktree/2`, dispatched from
  # `Worktree.clean/1`). The in-flight change also added it to
  # `PhaseSpec.@worktree_fields`, where it normalized a key no module read —
  # dead plumbing, removed with this fix.
  #
  # `on_success` is a real third value, not a synonym for `always`: the
  # worktree is reclaimed when the run finalizes successfully and RETAINED when
  # it fails, so a failed run's checkout survives for forensics. The
  # `Interpreter` has validated it as legal since the block was introduced,
  # while this function matched only `"never"` and sent everything else —
  # `on_success` included — to `:always`. A manifest asking to keep the
  # checkout on failure therefore had it deleted, silently doing the opposite
  # of what it declared on exactly the path where the evidence mattered.
  #
  # An unrecognized value is a hard failure, not a silent fall back to the
  # default (AGENTS.md 5.2/5.3): `cleanup: allways` must not read as a working
  # declaration that quietly does the opposite of what it says.
  defp worktree_cleanup(worktree) do
    case Map.get(worktree, :cleanup) do
      nil -> {:ok, :never}
      "never" -> {:ok, :never}
      :never -> {:ok, :never}
      "always" -> {:ok, :always}
      :always -> {:ok, :always}
      "on_success" -> {:ok, :on_success}
      :on_success -> {:ok, :on_success}
      other -> {:error, {:worktree_cleanup_invalid, other}}
    end
  end

  # `{run_id}` and `{task_id}` are placeholders. `{phase}` was dropped with the
  # move to a workflow-level, run-scoped worktree: it named a per-phase branch
  # and directory that no longer exist.
  defp render_worktree_template(template, state) when is_map(state) do
    template
    |> String.replace("{run_id}", state.run_id)
    |> String.replace("{task_id}", worktree_task_id(state))
  end

  defp render_worktree_template(template, run_id) when is_binary(run_id) do
    String.replace(template, "{run_id}", run_id)
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

  # Commits whatever the phase produced into the run's worktree. Foreman owns
  # the worktree, so Foreman owns the commit: an agent that writes files without
  # committing them still leaves the run with a proposable branch, and the next
  # phase's `base_ref` (the shared checkout's HEAD) advances to exactly what
  # this phase produced, which is what keeps the discovery gate scoped per
  # phase.
  #
  # A clean tree is `{:ok, :nothing_to_commit}` and creates no commit, so AutoPR
  # still opens a PR only when there is real work — never a phantom empty commit.
  #
  # Every other git failure is `{:error, …}`. The first implementation returned
  # `{:ok, :skipped_no_worktree}` for a failed `git add`, a missing
  # `project_root`, a non-zero `git commit`, and an unrecognized exit code
  # alike, so a phase whose work was never committed completed as a success and
  # AutoPR silently had nothing to propose — exactly the plausible-looking
  # success AGENTS.md 5.2 forbids.
  defp commit_phase_worktree(_state, _phase_spec, _phase_index, :no_worktree),
    do: {:ok, :no_worktree}

  defp commit_phase_worktree(_state, _phase_spec, _phase_index, nil), do: {:ok, :no_worktree}

  defp commit_phase_worktree(state, phase_spec, phase_index, %{worktree_path: path})
       when is_binary(path) and path != "" do
    if phase_commits?(phase_spec) do
      commit_dirty_worktree(state, phase_index, path)
    else
      # `commit: false` — the phase's work stays in the worktree for a later
      # phase to commit. Nothing is inspected and nothing is staged.
      #
      # Load-time validation no longer proves a later phase commits. That claim
      # was true of the unconditional refusal this replaced, and is now FALSE:
      # `Interpreter.validate_commit_cleanup!/3` refuses only the manifest whose
      # deferred work would be DESTROYED by `cleanup: always`/`on_success`. Under
      # `cleanup: never` the work may legitimately be stranded in the retained
      # worktree, which is what `warn_uncommitted_work/1` reports at run
      # terminal. Nor does load time prove anything about discovery gates: the
      # `requiredFile` clause that made deferral and discovery mutually exclusive
      # was deleted, since it forbade the batching this tag exists to provide.
      Logger.info(
        "RunExecutor #{state.run_id} phase #{phase_index} declares commit: false, deferring"
      )

      {:ok, :commit_deferred}
    end
  end

  # A worktree record without a usable path is a programming error, not a
  # condition to absorb: `maybe_create_worktree/3` returns either `nil` or a
  # record whose `:worktree_path` is a non-empty binary (AGENTS.md 5.3).
  defp commit_phase_worktree(_state, _phase_spec, phase_index, record) do
    raise ArgumentError,
          "phase #{phase_index} worktree record carries no worktree_path: #{inspect(record)}"
  end

  # Absent defaults to committing. That preserves the behavior from when the
  # commit was unconditional, and it keeps the two invariants deferral can
  # break (per-phase discovery scoping, AutoPR's commits-only gate) intact for
  # every manifest that says nothing — including the seven bundled workflows
  # that declare no `commit:` at all. Only an explicit `false` defers.
  #
  # A non-boolean cannot arrive here: `Interpreter.validate_commit_value!/3`
  # rejects it at load. This is a total match over `true | false | nil` rather
  # than a truthiness test so a value that somehow bypassed that boundary
  # raises instead of being silently coerced (AGENTS.md 5.2).
  defp phase_commits?(phase_spec) do
    case Map.get(phase_spec, :commit) do
      nil -> true
      true -> true
      false -> false
    end
  end

  @doc false
  # Test-only. `phase_commits?/1` is the single place the absent-means-commit
  # default lives, and it reads the ATOM `:commit` on a NORMALIZED PhaseSpec —
  # not the string-keyed manifest map. A test that hands it a raw parsed phase
  # gets `nil` for every input and passes vacuously, so the export exists to
  # make callers go through `PhaseSpec.normalize/1` as production does.
  def __phase_commits_for_test__(phase_spec), do: phase_commits?(phase_spec)

  @doc false
  def __failure_policy_for_test__(phase_spec) do
    AgentRuntime.FailurePolicy.resolve(
      phase_spec_name(phase_spec),
      phase_timeout_opts(phase_spec)
    )
  end

  defp commit_dirty_worktree(state, phase_index, path) do
    case worktree_dirty?(path) do
      {:ok, false} ->
        Logger.info(
          "RunExecutor #{state.run_id} phase #{phase_index} worktree clean, nothing to commit"
        )

        {:ok, :nothing_to_commit}

      {:ok, true} ->
        stage_and_commit(state, phase_index, path)

      {:error, reason} ->
        {:error, {:phase_commit_status_failed, path, reason}}
    end
  end

  # `git status --porcelain` is the decision, not `git commit`'s exit code.
  # Reading emptiness off `git commit` cannot work: after `git add -A` a clean
  # tree and a genuine failure both exit 1, and git prints "nothing to commit"
  # to stdout rather than staying silent — so the earlier "exit 1 with empty
  # output means clean" test matched the failure case and reported real errors
  # as a clean tree.
  #
  # `--untracked-files=all` so a phase whose only output is a new, never-added
  # file counts as dirty.
  defp worktree_dirty?(path) do
    args = ["-C", path, "status", "--porcelain", "--untracked-files=all"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output) != ""}
      {output, code} -> {:error, {:git_status_failed, code, String.trim(output)}}
    end
  end

  # Foreman commits as itself, with `-c` overrides rather than repository
  # config, so the commit cannot fail on a checkout with no `user.email` set and
  # is attributable to the harness rather than to the operator who happens to
  # own the clone. `--no-verify` because this is Foreman's bookkeeping commit:
  # a repository pre-commit hook must not be able to fail the phase or rewrite
  # the agent's output.
  defp stage_and_commit(state, phase_index, path) do
    with :ok <- git_ok(["-C", path, "add", "-A"], :git_add_failed),
         :ok <-
           git_ok(
             [
               "-C",
               path,
               "-c",
               "user.name=Foreman",
               "-c",
               "user.email=foreman@localhost",
               "commit",
               "--no-verify",
               "-m",
               "Foreman run #{state.run_id} phase #{phase_index}"
             ],
             :git_commit_failed
           ) do
      Logger.info("RunExecutor #{state.run_id} phase #{phase_index} committed worktree #{path}")
      {:ok, :committed}
    else
      {:error, reason} -> {:error, {:phase_commit_failed, path, reason}}
    end
  end

  # Exit status is the only success signal. Matching on empty output as well —
  # as the first implementation did for `git add` — mis-reads a successful
  # command that emitted a warning (CRLF conversion, embedded repository) as a
  # failure, and skips the commit.
  defp git_ok(args, error_tag) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {error_tag, code, String.trim(output)}}
    end
  end

  # The run's worktree is reclaimed once, when the run reaches a terminal state,
  # and only if the manifest asked for it. The declaration decides which
  # outcomes reclaim (default `never`):
  #
  #   * `never`      — never reclaimed here; `RunDeleted` still fans out to
  #                    `Worktree.clean_for_run/1`.
  #   * `always`     — reclaimed on success and on failure.
  #   * `on_success` — reclaimed on success only, so a failed run's checkout
  #                    survives for forensics.
  #
  # This replaced `cleanup_phase_worktree/4`, which ran in an `after` clause at
  # every phase boundary. With one worktree per run that is actively wrong: it
  # would delete the checkout the next phase is about to continue in.
  defp cleanup_run_worktree(state, outcome) when outcome in [:success, :failure] do
    warn_uncommitted_work(state)

    case {Map.get(state, :run_worktree), outcome} do
      {%{cleanup: :always} = record, _} -> do_clean_run_worktree(state, record)
      {%{cleanup: :on_success} = record, :success} -> do_clean_run_worktree(state, record)
      _ -> :ok
    end
  end

  # REQ-006. `Interpreter` refuses a manifest whose deferred work would be
  # DESTROYED by cleanup, because that is unsatisfiable; a manifest that merely
  # leaves work uncommitted in a retained worktree is legitimate and loads. The
  # consequence, though, is invisible: `AutoPR` gates on
  # `git rev-list --count base..head`, which counts commits only, so the run
  # reports success and simply produces no PR. Without this line the operator
  # has an absent PR and nothing anywhere attributing it.
  #
  # This replaced a LOAD-TIME raise on the same condition. The raise could not
  # distinguish "authored a review-staging workflow" from "made a mistake", so
  # it forbade the former outright. Warning here is strictly more informative
  # as well as more permissive: it fires against a real run, naming the phase.
  #
  # Emitted before cleanup and on every terminal path — including a run that
  # failed before reaching any committing phase, which is the case an
  # end-of-pipeline check would miss entirely, since the later committing phase
  # that would have absorbed the work never ran. That means the predicate reads
  # the phases that actually EXECUTED, not the whole manifest.
  defp warn_uncommitted_work(state) do
    executed = executed_phase_specs(state)

    case CommitDeferral.pending_phase_spec(executed) do
      nil ->
        :ok

      pending ->
        Logger.warning(
          "RunExecutor #{state.run_id} left work uncommitted: phase #{pending} " <>
            "(#{phase_spec_name(Enum.at(executed, pending))}) declared \"commit: false\" and no " <>
            "later phase that ran committed it. The changes remain in the run's worktree; " <>
            "AutoPR proposes commits only, so this run has no PR to show for that work."
        )
    end
  end

  # Only the phases that RAN. A run that fails at phase 1 of 3 must be judged on
  # phase 1 alone: the manifest's later committing phase is not a defence for
  # work that was never absorbed because execution stopped first.
  #
  # `completed` holds phase INDICES, so the count of executed phases is the
  # highest index reached plus one — not `length/1`, which would undercount if
  # an index were ever recorded out of order.
  defp executed_phase_specs(state) do
    specs = Map.get(state, :phase_specs) || []

    case Map.get(state, :completed) || [] do
      [] -> []
      completed -> Enum.take(specs, Enum.max(completed) + 1)
    end
  end

  defp do_clean_run_worktree(state, record) do
    _ = unbind_vfs(state.run_id)

    Worktree.clean(%{
      operation_id: record.operation_id,
      project_id: record.project_id,
      run_id: state.run_id,
      phase_id: Identity.phase_id(state.run_id, 1),
      repo_path: record.project_root
    })
    |> case do
      :ok ->
        :ok

      {:ok, :already_cleaned} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RunExecutor #{state.run_id} worktree cleanup reported: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Env injection (TRD Decision 9). Every phase gets the shell-session
  # export so the common non-worktree path can still bind to the
  # executor-owned shell lifecycle. Worktree-managed phases add the
  # remaining Foreman worktree markers below.
  # A `command:` phase never receives Foreman's rendered prompt — the command
  # string replaces it (see execute_agent/4) — so Foreman has no in-prompt
  # channel to tell the agent where it will look for the artifact. Agents wrote
  # to a convention they inferred while `ArtifactTemplate.describe/1` read the
  # path Foreman computed, so no run ever recorded an artifact. Export it.
  #
  # Consumed by the ensemble commands' `--foreman` path (Sunstone/ensemble,
  # `packages/development/commands/*.yaml`): when set, the phase report is
  # written to this exact path in addition to any repo-local report.
  defp artifact_path_for(state, phase_spec, index) do
    __MODULE__.ArtifactTemplate.path(state, phase_spec, prompt_phase_index(phase_spec, index))
  end

  defp foreman_env(state, nil, artifact_path, nil) do
    %{"FOREMAN_ARTIFACT_PATH" => artifact_path}
    |> put_plan_env(state, nil)
    |> maybe_put_shell_session_env(state)
  end

  defp foreman_env(state, nil, artifact_path, model) when is_binary(model) and model != "" do
    %{"FOREMAN_ARTIFACT_PATH" => artifact_path, "FOREMAN_MODEL" => model}
    |> put_plan_env(state, nil)
    |> maybe_put_shell_session_env(state)
  end

  defp foreman_env(state, worktree_record, artifact_path, nil) do
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
        "FOREMAN_IMPLEMENTATION_KEY" => implementation_key,
        "FOREMAN_ARTIFACT_PATH" => artifact_path
      }
      |> put_plan_env(state, worktree_record)
      |> maybe_put_shell_session_env(state)

    case Map.get(plan_context, "beads_database_path") do
      nil ->
        base_env

      "" ->
        base_env

      path ->
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

  defp foreman_env(state, worktree_record, artifact_path, model)
       when is_binary(model) and model != "" do
    plan_context = Map.put(state.plan_context || %{}, "FOREMAN_MODEL", model)
    implementation_key = worktree_record.implementation_key || ""

    _ = bind_vfs(state.run_id, worktree_record.worktree_path)

    base_env =
      %{
        "FOREMAN_WORKTREE" => "1",
        "FOREMAN_RUN_ID" => state.run_id,
        "FOREMAN_WORKTREE_PATH" => worktree_record.worktree_path,
        "FOREMAN_EXPECTED_BRANCH" => worktree_record.branch,
        "FOREMAN_SOURCE_REVISION" => worktree_record.base_ref,
        "FOREMAN_IMPLEMENTATION_KEY" => implementation_key,
        "FOREMAN_ARTIFACT_PATH" => artifact_path
      }
      |> put_plan_env(state, worktree_record)
      |> maybe_put_foreman_model(model)
      |> maybe_put_shell_session_env(state)

    case Map.get(plan_context, "beads_database_path") do
      nil ->
        base_env

      "" ->
        base_env

      path ->
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

  # The subject of the dispatched task, and the document a previous phase
  # produced. A `command:` phase gets no rendered prompt — the prompt is
  # literally the command string — so env is the only channel Foreman has
  # to a `command:` agent.
  #
  # `FOREMAN_TASK_TITLE` / `FOREMAN_TASK_DESCRIPTION` are the authoritative
  # subject. Without them a plan agent has nothing to plan and infers a
  # topic from repository contents, which is how three consecutive runs all
  # produced a PRD about the same unrelated subject. `plan_subject_env/1`
  # is what `assert_plan_subject/3` checks before dispatch.
  #
  # `FOREMAN_SOURCE_PRD_PATH` is an INPUT: the PRD an earlier phase actually
  # wrote, discovered by `enforce_required_file/4` and threaded through the
  # plan context. It is absent on the phase that produces the PRD and
  # present for every phase after it, so `create-trd` consumes a named
  # document instead of guessing which file under `docs/PRD` is the one.
  # Deliberately NOT named `FOREMAN_PRD_PATH`: that variable meant "write
  # here", it is deleted, and reusing the name for "read here" would leave
  # two contradictory meanings in circulation.
  #
  # Every key is omitted when its value is missing or empty — absent, never
  # blank — so a non-plan run exports none of them.
  defp maybe_put_driver_model(opts, model) when is_binary(model) and model != "" do
    Keyword.put(opts, :model, model)
  end

  defp maybe_put_driver_model(opts, _model), do: opts

  defp maybe_put_foreman_model(env, model)
       when is_map(env) and is_binary(model) and model != "" do
    Map.put(env, "FOREMAN_MODEL", model)
  end

  defp maybe_put_foreman_model(env, _model) when is_map(env) do
    env
  end

  defp put_plan_env(env, state, worktree_record) do
    env
    |> Map.merge(plan_subject_env(state))
    |> put_source_prd_path(state, worktree_record)
  end

  defp plan_subject_env(state) do
    # Check plan_context["task"] first (for plan workflows), then fall back to state.task
    # (for all workflows including prd, implement, etc.)
    # Note: state.task uses atom keys from the projection
    plan_task = Map.get(state.plan_context || %{}, "task") || %{}
    fallback_task = state.task || %{}

    Enum.reduce(
      [{"FOREMAN_TASK_TITLE", :title}, {"FOREMAN_TASK_DESCRIPTION", :description}],
      %{},
      fn {var, key}, acc ->
        value =
          Map.get(plan_task, key) || Map.get(plan_task, to_string(key)) ||
            Map.get(fallback_task, key) || Map.get(fallback_task, to_string(key))

        case value do
          v when is_binary(v) and v != "" -> Map.put(acc, var, v)
          _ -> acc
        end
      end
    )
  end

  defp put_source_prd_path(env, state, worktree_record) do
    planning = Map.get(state.plan_context || %{}, "planning") || %{}

    path =
      case Map.get(planning, "prd_path") do
        p when is_binary(p) and p != "" -> p
        _ -> discover_prd_path(state, worktree_record)
      end

    case path do
      p when is_binary(p) and p != "" ->
        Map.put(env, "FOREMAN_SOURCE_PRD_PATH", resolve_phase_path(p, state, worktree_record))

      _ ->
        env
    end
  end

  # For prd workflows, discover PRD from worktree if a prior phase completed
  defp discover_prd_path(state, worktree_record) do
    if state.completed != [] do
      working_directory = working_directory_for(state, worktree_record)

      # Use git to find the most recently added PRD file
      case System.cmd(
             "git",
             [
               "-C",
               working_directory,
               "log",
               "--diff-filter=A",
               "--name-only",
               "-1",
               "--pretty=format:",
               "HEAD",
               "--",
               "docs/PRD/*.md"
             ],
             stderr_to_stdout: true
           ) do
        {output, 0} when output != "" ->
          # output is the file path, e.g. "docs/PRD/PRD-2026-xxx.md"
          # Extract just the relative path
          case String.split(String.trim(output), "\n") do
            [path | _] when is_binary(path) and path != "" ->
              Logger.debug("discover_prd_path: found PRD at #{path}")
              path

            _ ->
              Logger.debug(
                "discover_prd_path: no PRD found in git log output: #{inspect(output)}"
              )

              nil
          end

        _ ->
          Logger.debug("discover_prd_path: git log failed or no PRD found")
          nil
      end
    else
      nil
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

  defp worktree_task_id(state) do
    case Map.get(state.task, :external_id) || Map.get(state.task, "external_id") ||
           Map.get(state.task, :task_id) || Map.get(state.task, "task_id") ||
           Map.get(state.task, :work_id) || Map.get(state.task, "work_id") ||
           Map.get(state.task, :id) || Map.get(state.task, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> state.run_id
    end
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

  # `phase_lineage_base_ref/2` and its export are gone: with one worktree per
  # run there is no predecessor branch to chain a base from. `reuse_run_worktree/2`
  # supplies the per-phase base from the shared checkout's HEAD instead.
  @doc false
  def __reuse_run_worktree_for_test__(record, path), do: reuse_run_worktree(record, path)

  @doc false
  def __commit_phase_worktree_for_test__(state, phase_spec, record),
    do: commit_phase_worktree(state, phase_spec, 1, record)

  @doc false
  def __worktree_cleanup_for_test__(worktree), do: worktree_cleanup(worktree)

  @doc false
  def __warn_uncommitted_work_for_test__(state), do: warn_uncommitted_work(state)

  @doc false
  def __remember_run_base_branch_for_test__(state), do: remember_run_base_branch(state)

  @doc false
  def __run_base_branch_for_test__(state), do: run_base_branch(state)

  @doc false
  def __fetch_project_id_for_test__(task), do: fetch_project_id(%{task: task})

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

  # Phase specs are normalized to canonical atom keys by
  # `PhaseSpec.normalize/1` at `extract_phase_specs/1`, the single funnel
  # through which every spec enters the executor. That absorbs both inbound
  # shapes — the hybrid map `Catalog.resolve_workflow/3` builds in memory and
  # the fully string-keyed one that comes back when the `TaskApproved`
  # snapshot is JSON-decoded on replay — so reads here are plain atom
  # lookups. `phase_value/2` remains as the single named read point.
  defp phase_value(phase_spec, key) when is_atom(key) do
    Map.get(phase_spec, key)
  end

  # `:action` is derived by `PhaseSpec.normalize/1` from the command/bash
  # fields, so it is always one of `:command`, `:bash`, `:prompt` — never a
  # JSON-round-tripped binary. The former "command"/"bash" string remap here
  # was compensation for the un-normalized shape and would now mask a
  # normalizer defect rather than tolerate a legitimate input.
  defp phase_action(phase_spec) do
    phase_value(phase_spec, :action)
  end

  defp phase_spec_name(phase_spec) do
    Map.get(phase_spec, :name) || ""
  end

  defp phase_timeout_opts(phase_spec) do
    case Map.get(phase_spec, :timeout_minutes) do
      nil -> []
      minutes when is_integer(minutes) -> [timeout_ms: minutes * 60_000]
    end
  end

  defp phase_number(phase_spec, index) do
    case Map.get(phase_spec, :index) do
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

  # An ad-hoc task carries no tracker record, so provider callbacks must not fire.
  defp provider_tracked?(state) do
    case Map.get(state.task, :provider_tracked, Map.get(state.task, "provider_tracked", true)) do
      false -> false
      _ -> true
    end
  end

  # For work-sourced runs there is no task to claim — skip the callback entirely.
  defp maybe_claim_task(state) do
    if state.source == :work_request do
      :ok
    else
      case provider_tracked?(state) and provider_enabled?(project_id(state)) do
        true ->
          claim(project_id(state), provider_task_id(state), task_provider_actor(), state.run_id)
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
      case provider_tracked?(state) and provider_enabled?(project_id(state)) do
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
      case provider_tracked?(state) and provider_enabled?(project_id(state)) do
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
    # `cleanup: always` means always, including the failure path. `on_success`
    # deliberately retains the checkout here so a failed run can be inspected;
    # that distinction is the whole reason `on_success` is not a synonym for
    # `always`.
    _ = cleanup_run_worktree(state, :failure)

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

  defp resolve_provider(project_id, transition, run_id) do
    with {:ok, project} <- fetch_project_projection(project_id),
         {:ok, task_provider} <- fetch_task_provider(project),
         {:ok, project_config} <- fetch_project_config(task_provider),
         {:ok, database_path} <- fetch_database_path(project_config),
         {:ok, provider_module} <-
           TaskProviderRegistry.route(transition, {project_id, database_path}) do
      project_config =
        if run_id && run_id != "",
          do: Map.put(project_config, :run_id, run_id),
          else: project_config

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
      {:error, _} = err -> err
    end
  end

  defp fetch_plan_base(task_projection) do
    case ForemanServer.Workflow.PlanContext.build(task_projection) do
      {:ok, ctx} -> {:ok, ctx}
      {:not_applicable, _} -> {:ok, %{}}
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

  # Post-agent gate. Returns the run state, updated with whatever the phase
  # captured, so a discovered planning document reaches the next phase.
  #
  # Two kinds of gate share the `requiredFile` key:
  #
  #   * A planning document (`planning.prd_path`, `planning.trd_path`) is
  #     DISCOVERED. Foreman does not name the file and does not require the
  #     agent to reproduce a name — that contract failed in three
  #     consecutive live runs. `PlanContext.discover_document/3` asks git
  #     what new document appeared since the phase's base commit, and the
  #     answer is captured into the plan context under the same key.
  #   * Every other key still names a context value that must resolve to an
  #     existing file (the frozen ImplementationContext's `trd_path`, which
  #     Foreman validated at approval and the agent only reads).
  defp enforce_required_file(state, phase_spec, phase_index, worktree_record) do
    case Map.get(phase_spec, :required_file) do
      nil ->
        {:ok, state}

      "" ->
        {:error, {:required_file_blank, phase_index}}

      key when is_binary(key) ->
        case PlanContext.document_dir(key) do
          nil -> enforce_context_file(state, key, phase_index, worktree_record)
          docs_dir -> capture_planning_document(state, key, docs_dir, worktree_record)
        end

      _ ->
        {:error, {:required_file_invalid, phase_index}}
    end
  end

  defp enforce_context_file(state, key, phase_index, worktree_record) do
    case resolve_context_key(state, key, phase_index) do
      {:ok, path} ->
        absolute_path = resolve_phase_path(path, state, worktree_record)

        if File.regular?(absolute_path) do
          {:ok, state}
        else
          {:error, {:required_file_missing, key, absolute_path}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The captured path is threaded into the run's own plan context, which is
  # what `context_for/2` and `base_context/4` hand the NEXT phase — so
  # `create-trd` reads the PRD the `create-prd` agent actually wrote rather
  # than one Foreman invented. Discovery failures propagate verbatim; each
  # cause has its own tuple (see `PlanContext.discover_document/3`).
  defp capture_planning_document(state, key, docs_dir, worktree_record) do
    working_directory = working_directory_for(state, worktree_record)
    base_ref = phase_base_ref(worktree_record)

    case PlanContext.discover_document(working_directory, docs_dir, base_ref) do
      {:ok, relative_path} ->
        {:ok,
         %{
           state
           | plan_context:
               PlanContext.capture_document(state.plan_context || %{}, key, relative_path)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The commit the phase's checkout was created at. Discovery needs it
  # because an agent that COMMITS its document leaves nothing in the
  # working tree to scan; `base_ref..HEAD` is where that document is.
  # `Worktree.create/1` pins the worktree to this revision and both
  # `create_phase_worktree/4` and `create_default_worktree/3` carry it back
  # on the record, so no new event is needed. A phase that ran with no
  # worktree has no recorded base: nil travels through to
  # `:planning_document_base_unknown` rather than silently degrading the
  # gate to a working-tree-only scan that cannot see a committed document.
  defp phase_base_ref(%{base_ref: base_ref}) when is_binary(base_ref) and base_ref != "",
    do: base_ref

  defp phase_base_ref(_), do: nil

  # The ONE rule that turns a context path into an absolute one: paths live
  # in the same working directory the agent executed in — the phase worktree
  # when one is active, otherwise the project's working directory. Relative
  # paths resolve against that root so `File.regular?/1` checks the file the
  # agent actually had access to, not the daemon's cwd. Absolute paths (the
  # frozen ImplementationContext can carry one) pass through.
  #
  # A discovered planning document is stored relative for the same reason:
  # git reports it relative to the repository root, and only the consuming
  # phase knows which checkout it is looking at.
  defp resolve_phase_path(path, state, worktree_record) when is_binary(path) do
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
