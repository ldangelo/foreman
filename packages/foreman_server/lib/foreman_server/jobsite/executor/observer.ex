defmodule ForemanServer.Jobsite.Executor.Observer do
  @moduledoc """
  `ForemanServer.Jobsite.Observer` implementation used by
  `ForemanServer.Jobsite.Executor` for a fresh (non-resumed) run: dispatches
  the same `jobsite.*` commands the hand-rolled executor used to dispatch
  inline, in the same order, with the same payload shapes.

  `state` is `%{jobsite_id: String.t(), sandbox_attempt: non_neg_integer()}`
  — `sandbox_attempt` increments on every `:sandbox` step completion so a
  resumed run (handled separately, outside this module) can continue the
  same attempt sequence.
  """

  @behaviour ForemanServer.Jobsite.Observer

  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite.{Error, IterationResult}

  @impl true
  def step_started(%{kind: :agent} = step, _ctx, state) do
    index = Map.fetch!(step.opts, :iteration_index)
    resume_session = Map.get(step.opts, :resume_session)

    case dispatch(state, "jobsite.iteration.start", "iteration:#{index}:start", %{
           index: index,
           resumed_session_id: resume_session
         }) do
      {:ok, _} -> {:ok, state}
      {:error, %Error{}} = err -> err
    end
  end

  def step_started(_step, _ctx, state), do: {:ok, state}

  @impl true
  def step_completed(%{kind: :worktree}, ctx, {:worktree, worktree, _}, state) do
    with {:ok, _} <-
           dispatch(state, "jobsite.worktree.provision", "worktree", %{
             path: worktree.path,
             branch: worktree.branch,
             base_sha: worktree.base_sha
           }) do
      {:ok, ctx, state}
    end
  end

  def step_completed(%{kind: :sandbox}, ctx, {:sandbox, sandbox}, state) do
    attempt = Map.get(state, :sandbox_attempt, 0) + 1
    state = Map.put(state, :sandbox_attempt, attempt)

    with {:ok, _} <-
           dispatch(state, "jobsite.sandbox.provision", "sandbox:#{attempt}", %{
             provider: sandbox.provider.name(),
             sandbox_repo_path: sandbox.sandbox_repo_path,
             container_id: sandbox.container_id
           }) do
      {:ok, ctx, state}
    end
  end

  def step_completed(%{kind: :hook}, ctx, {:hook, _result}, state), do: {:ok, ctx, state}
  def step_completed(%{kind: :exec}, ctx, {:exec, _result}, state), do: {:ok, ctx, state}
  def step_completed(%{kind: :gate}, ctx, {:gate, _, _}, state), do: {:ok, ctx, state}

  def step_completed(
        %{kind: :agent} = step,
        ctx,
        {:agent_iteration, %IterationResult{} = result},
        state
      ) do
    index = Map.fetch!(step.opts, :iteration_index)

    with {:ok, _} <-
           dispatch(state, "jobsite.iteration.complete", "iteration:#{index}:done", %{
             index: index,
             status: Atom.to_string(result.status),
             text: result.text,
             text_truncated?: result.text_truncated?,
             session_id: result.session_id,
             usage: result.usage,
             signalled?: result.signalled?,
             matched_signal: result.matched_signal
           }) do
      {:ok, ctx, state}
    end
  end

  def step_completed(
        %{kind: :agent} = step,
        ctx,
        {:agent_iteration_failed, %Error{} = error},
        state
      ) do
    index = Map.fetch!(step.opts, :iteration_index)

    dispatch(state, "jobsite.iteration.fail", "iteration:#{index}:done", %{
      index: index,
      code: Atom.to_string(error.code),
      message: error.message,
      details: error.details
    })

    {:ok, ctx, state}
  end

  def step_completed(%{kind: :agent}, ctx, {:agent, _iterations}, state) do
    case ctx.output do
      nil ->
        {:ok, ctx, state}

      output ->
        with {:ok, _} <-
               dispatch(state, "jobsite.output.capture", "output", %{tag: "output", value: output}) do
          {:ok, ctx, state}
        end
    end
  end

  def step_completed(%{kind: :commit}, ctx, {:commit, outcome}, state) do
    with {:ok, commits} <- commits_record(ctx, outcome),
         {:ok, _} <- dispatch(state, "jobsite.commits.record", "commits", %{commits: commits}) do
      {:ok, %{ctx | commits: commits}, state}
    end
  end

  def step_completed(%{kind: :push}, ctx, {:push, _remote, _branch}, state), do: {:ok, ctx, state}

  def step_completed(%{kind: :release}, ctx, {:release, _sandbox_release, release_info}, state) do
    merged? = (release_info && release_info[:merged?]) || false
    preserved_path = release_info && release_info[:preserved_path]

    with {:ok, _} <-
           dispatch(state, "jobsite.sandbox.release", "sandbox-release", %{
             container_id: ctx.sandbox && ctx.sandbox.container_id
           }),
         {:ok, _} <-
           dispatch(state, "jobsite.worktree.release", "worktree-release", %{
             merged?: merged?,
             preserved_path: preserved_path
           }) do
      {:ok, %{ctx | merged?: merged?, preserved_path: preserved_path}, state}
    end
  end

  # A clean tree at the commit step does NOT mean the run made no commits: an
  # agent that commits its own work (the usual case for Claude and Pi) leaves
  # nothing for Foreman to commit, yet those commits are exactly what the
  # result reports. Only a deferred commit has nothing to collect yet.
  defp commits_record(ctx, outcome) when outcome in [:nothing_to_commit, :committed] do
    ForemanServer.Jobsite.Git.commits_between(ctx.worktree.path, ctx.worktree.base_sha, "HEAD")
  end

  defp commits_record(ctx, :deferred), do: {:ok, ctx.commits}

  defp dispatch(state, type, suffix, payload) do
    jobsite_id = Map.fetch!(state, :jobsite_id)

    command = %{
      type: type,
      command_id: "jobsite:#{jobsite_id}:#{suffix}",
      aggregate_id: "jobsite:#{jobsite_id}",
      payload: Map.put(payload, :jobsite_id, jobsite_id)
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        {:error, Error.new(:dispatch_rejected, "dispatch #{type} rejected", %{reason: reason})}
    end
  end
end
