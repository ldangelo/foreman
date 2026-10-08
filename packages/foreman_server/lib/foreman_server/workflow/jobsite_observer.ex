defmodule ForemanServer.Workflow.JobsiteObserver do
  @moduledoc """
  `ForemanServer.Jobsite.Observer` for a program compiled by
  `ForemanServer.Workflow.Lowering`: everything Foreman-specific about running
  a workflow phase, so none of it lives in `ForemanServer.Jobsite.Engine`.

  `state` is `%{executor: RunExecutor.state(), phase: phase | nil}` — the
  `RunExecutor`'s own run state, threaded through every callback and handed
  back in the engine's outcome, so `RunExecutor` carries on from exactly the
  state the phases left it in (`completed`, `plan_context`, `run_worktree`,
  `last_worktree`, ...). `phase` is what is known about the phase in flight:
  `%{idx, spec, number, record, body?, artifact_path}`.

  The phase hooks themselves are `RunExecutor`'s (`phase_begin/3`,
  `phase_launch/4`, `enforce_required_file/4`, `phase_finish/5`, `emit_phase_failure/4`,
  `handle_phase_body_error/6`) — they take and return the executor state, and
  the observer only decides WHEN each runs:

  | callback | effect |
  |---|---|
  | `step_started` on a phase's first step | `phase.start`, then the run's worktree is provisioned (first phase) or re-entered with its `base_ref` refreshed (every later phase) |
  | `step_started` on `:worktree` | hands the engine the worktree just provisioned (`provided`) |
  | `step_started` on `:agent` (iteration 1) | asserts the plan subject and builds the `launch` the Overwatch runner dispatches |
  | `step_completed` on `:agent` | `ArtifactTemplate.write/4`; sets `ctx.artifact_path` |
  | `step_completed` on `:gate` | `enforce_required_file/4`; a captured planning document is written back into the run's plan context |
  | `step_completed` on `:commit` | phase PR record when `stack_pr: true`, then `phase.complete` |
  | `step_failed` | `phase.fail`, or — for a failure inside the phase body while the operator has asked to pause or cancel — the pause/cancel handling below |

  **Pause and cancel.** A request landing between phases is the engine's own
  `:intent` check. One landing DURING a phase arrives as the agent's death
  (the dispatcher kills the harness run); `step_failed/4` reads
  `RunControl.intent/1` and, for a pause, commits the partial work to the run
  branch before reporting `{:interrupted, :pause, ...}`; for a cancel it stops
  without committing. With no intent recorded the failure is a failure. That
  is `RunExecutor.handle_phase_body_error/6`, unchanged — the observer only
  reports its verdict to the engine.

  A failure BEFORE the phase body begins (the phase's worktree could not be
  provisioned) is always a failure, never a pause: nothing has been produced
  to commit.

  `phase.start` fires from the phase's first step rather than the agent's, so
  its position relative to the worktree matches what `RunExecutor` always
  did: started, then provisioned. It is idempotent per phase regardless —
  `phase_begin/3` runs once per phase because `phase` is set once, and the
  command carries a deterministic id besides.
  """

  @behaviour ForemanServer.Jobsite.Observer

  alias ForemanServer.Jobsite.{Error, Step}
  alias ForemanServer.Jobsite.Worktree, as: JobsiteWorktree
  alias ForemanServer.Workflow.{PhaseSpec, RunExecutor}
  alias ForemanServer.Workflow.RunExecutor.ArtifactTemplate

  require Logger

  @type phase :: %{
          idx: non_neg_integer(),
          spec: map(),
          number: pos_integer(),
          record: map() | nil,
          body?: boolean(),
          artifact_path: String.t() | nil
        }

  @type t :: %{executor: map(), phase: phase() | nil}

  @spec new(map()) :: t()
  def new(executor), do: %{executor: executor, phase: nil}

  @impl true
  def step_started(%Step{kind: kind, opts: %{phase_idx: idx} = opts}, _ctx, state) do
    with {:ok, state} <- enter_phase(state, idx) do
      case {kind, opts} do
        {:worktree, _} -> provide_worktree(state)
        {:agent, %{iteration_index: 1}} -> launch_agent(state)
        _ -> {:ok, state}
      end
    end
  end

  @impl true
  def step_completed(%Step{kind: :agent}, ctx, {:agent, iterations}, state) do
    %{phase: phase, executor: executor} = state

    case ArtifactTemplate.write(executor, phase.spec, phase.number, List.last(iterations).text) do
      {:ok, path} ->
        {:ok, %{ctx | artifact_path: path}, put_in(state.phase.artifact_path, path)}

      {:error, reason} ->
        {:error, failure(:artifact_write_failed, "writing the phase artifact failed", reason)}
    end
  end

  def step_completed(%Step{kind: :gate}, ctx, {:gate, _opts}, state) do
    %{phase: phase, executor: executor} = state

    case RunExecutor.enforce_required_file(executor, phase.spec, phase.number, phase.record) do
      {:ok, executor} -> {:ok, ctx, %{state | executor: executor}}
      {:error, reason} -> {:error, failure(:required_file_failed, "the phase's required file gate failed", reason)}
    end
  end

  def step_completed(%Step{kind: :commit}, ctx, {:commit, outcome}, state) do
    %{phase: phase, executor: executor} = state

    if outcome == :deferred and phase.record != nil do
      Logger.info("RunExecutor #{executor.run_id} phase #{phase.number} declares commit: false, deferring")
    end

    case RunExecutor.phase_finish(executor, phase.spec, phase.idx, phase.record, phase.artifact_path) do
      {:ok, executor} -> {:ok, ctx, %{state | executor: executor, phase: nil}}
      {:error, reason} -> {:error, failure(:phase_finish_failed, "recording the phase's completion failed", reason)}
    end
  end

  # Worktree, per-iteration agent results, and anything else: nothing to
  # record — the work happens in the callbacks above.
  def step_completed(_step, ctx, _result, state), do: {:ok, ctx, state}

  @impl true
  def step_failed(%Step{opts: %{phase_idx: idx}}, %Error{} = error, _ctx, state) do
    phase = phase_for(state, idx)
    reason = failure_reason(error, phase)

    if phase.body? do
      body_failure(state, phase, reason)
    else
      start_failure(state, phase, reason)
    end
  end

  # ---------------------------------------------------------------------
  # Phase entry
  # ---------------------------------------------------------------------

  defp enter_phase(%{phase: %{idx: idx}} = state, idx), do: {:ok, state}

  defp enter_phase(%{executor: executor} = state, idx) do
    phase = fresh_phase(executor, idx)

    case RunExecutor.phase_begin(executor, phase.spec, idx) do
      {:ok, executor, record} ->
        {:ok, %{state | executor: executor, phase: %{phase | record: record, body?: true}}}

      {:error, reason} ->
        {:error, failure(:phase_start_failed, "the phase could not start", reason)}
    end
  end

  defp fresh_phase(executor, idx) do
    spec = Enum.at(executor.phase_specs, idx)
    %{idx: idx, spec: spec, number: PhaseSpec.number(spec, idx), record: nil, body?: false, artifact_path: nil}
  end

  # The failing step's phase: the one in flight when it matches, else one the
  # observer never got to enter (its `phase_begin/3` is what failed).
  defp phase_for(%{phase: %{idx: idx} = phase}, idx), do: phase
  defp phase_for(%{executor: executor}, idx), do: fresh_phase(executor, idx)

  # The engine's `:worktree` step takes the worktree the observer provisioned;
  # it never provisions one itself for a manifest run.
  defp provide_worktree(%{phase: %{record: nil}}) do
    {:error, Error.new(:worktree_create_failed, "a worktree step was lowered for a workflow that disables its worktree", %{})}
  end

  defp provide_worktree(%{phase: %{record: record}} = state) do
    worktree = %JobsiteWorktree{
      repo_path: record.project_root,
      path: record.worktree_path,
      branch: record.branch,
      strategy: {:branch, record.branch},
      base_sha: record.base_ref
    }

    {:ok, state, %{provided: worktree}}
  end

  defp launch_agent(%{executor: executor, phase: phase} = state) do
    case RunExecutor.phase_launch(executor, phase.spec, phase.idx, phase.record) do
      {:ok, launch} -> {:ok, state, %{launch: launch}}
      {:error, reason} -> {:error, failure(:agent_start_failed, "the phase's agent could not be launched", reason)}
    end
  end

  # ---------------------------------------------------------------------
  # Failure
  # ---------------------------------------------------------------------

  # A failure while the phase body ran. `handle_phase_body_error/6` folds it
  # into a pause (commit the partial work), a cancel (stop clean), or the
  # ordinary `phase.fail` path, and `{:error, _}` there is either the original
  # reason or the lifecycle dispatch's own failure — both are the reason the
  # run reports.
  defp body_failure(%{executor: executor} = state, phase, reason) do
    case RunExecutor.handle_phase_body_error(executor, phase.spec, phase.number, phase.record, reason, {:error, reason}) do
      {:stopped, %{status: :paused} = executor} -> {:interrupted, :pause, "paused", %{state | executor: executor}}
      {:stopped, %{status: :cancelled} = executor} -> {:interrupted, :cancel, "cancelled", %{state | executor: executor}}
      {:error, reported} -> {:error, phase_failure(reported, phase), state}
    end
  end

  # The phase never got as far as a body, so there is nothing to pause or
  # commit: it is a failure whatever the operator has asked for.
  defp start_failure(%{executor: executor} = state, phase, reason) do
    reported =
      case RunExecutor.emit_phase_failure(executor, phase.spec, phase.number, reason) do
        :ok -> reason
        {:error, lifecycle_reason} -> lifecycle_reason
      end

    {:error, phase_failure(reported, phase), state}
  end

  # `phase_idx` is how `RunExecutor` knows WHICH phase failed — the first one
  # to run reports as an initialization failure, a later one as that phase's
  # start failure.
  defp phase_failure(reason, phase),
    do: Error.new(:phase_failed, "the phase failed", %{reason: reason, phase_idx: phase.idx})

  # The exact reason `RunExecutor` has always reported for a phase failure.
  # Runner and observer errors carry it in `details.reason`; a commit failure
  # from the engine's `:commit` step is mapped back onto the two tuples the
  # executor's own commit path produces, which say which git step failed.
  defp failure_reason(%Error{code: :commit_failed, details: %{stage: :status, reason: reason}}, phase),
    do: {:phase_commit_status_failed, phase.record.worktree_path, reason}

  defp failure_reason(%Error{code: :commit_failed, details: %{reason: reason}}, phase),
    do: {:phase_commit_failed, phase.record.worktree_path, reason}

  defp failure_reason(%Error{details: %{reason: reason}}, _phase), do: reason
  defp failure_reason(%Error{} = error, _phase), do: error

  defp failure(code, message, reason), do: Error.new(code, message, %{reason: reason})
end
