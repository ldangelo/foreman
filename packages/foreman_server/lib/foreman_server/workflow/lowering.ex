defmodule ForemanServer.Workflow.Lowering do
  @moduledoc """
  Compiles a parsed workflow manifest's phase list into a
  `ForemanServer.Jobsite.Program` that `ForemanServer.Jobsite.Engine.run_program/3`
  executes — the manifest front-end to the one engine
  `ForemanServer.Jobsite.Executor` also uses for scripts.

  `phase_specs` is the list `PhaseSpec.normalize_all/1` already produces: one
  plain map per phase, atom-keyed, absent keys omitted rather than `nil`
  (§5.4b). `ctx` carries the run-level values lowering needs:

    * `:run_id` (required)
    * `:worktree_spec` — the workflow's `worktree:` block as
      `WorktreeSpec.normalize/1` returns it, or `nil`; `enabled: false` means
      the program has no `:worktree` step and runs against the project checkout
    * `:start_index` — the 0-based list index of the first phase to run
      (`RunExecutor`'s `resume_from`); earlier phases are not lowered

  Each phase lowers to this step sequence:

    1. `:worktree` — only for the FIRST phase of the program: a run has one
       worktree. The step carries no provisioning detail; provisioning is
       `RunExecutor`'s (`ensure_run_worktree/2` and its path containment,
       ImplementationContext base pinning and `.beads/` exclusion), which the
       observer performs and hands the engine as `provided`. Duplicating that
       computation here would be a second, unchecked copy of it.
    2. `:agent` — `Jobsite.Runners.Overwatch`, one iteration, no completion
       signal (the runner supports neither). Everything the dispatch needs —
       request, 13-variable env, deadline, heartbeat-lease identity — derives
       from run state and is built by the observer at the moment the step
       starts, then reaches the runner as `launch`.
    3. `:gate` — only when the phase declares `required_file:`.
    4. `:commit` — always, with `defer?: true` when the phase declares
       `commit: false`. An absent `:commit` key means commit, matching
       `RunExecutor.phase_commits?/1`'s `nil -> true` clause, the authority.

  Every step carries `phase_idx` (the phase's list index). Only the first
  step of a phase is interruptible: an operator's pause or cancel is honoured
  between phases, never between the steps that finish one — the agent's work
  must reach its commit, and the `:gate`/`:commit` steps are marked
  `uninterruptible`. A pause that lands DURING the agent arrives as the
  agent's death and is handled by the observer's `step_failed/4`, which
  commits the partial work.

  No `:sandbox` and no `:release` step is emitted. Manifest runs execute on
  the host in the Foreman worktree, and worktree reclamation stays with
  `RunExecutor.cleanup_run_worktree/2` because its
  `cleanup: always | never | on_success` policy is run-level, not
  program-level.

  Refused here, before any side effect, rather than mid-run: a `bash:` phase
  (`{:unsupported_phase_action, :bash}` — `bash:` is parsed and validated at
  load but has never been executable) and a `command:` phase without a
  command (`{:invalid_phase_command, name}`). The error's `details` carry the
  offending phase's list `:index` and the exact `:reason` `RunExecutor`
  reports for it.
  """

  alias ForemanServer.Jobsite.{Agent, Error, Program, Step}
  alias ForemanServer.Jobsite.Runners.Overwatch
  alias ForemanServer.Workflow.PhaseSpec

  @spec lower([map()], map()) :: {:ok, Program.t()} | {:error, Error.t()}
  def lower(phase_specs, ctx) when is_list(phase_specs) and is_map(ctx) do
    run_id = Map.fetch!(ctx, :run_id)
    start_index = Map.get(ctx, :start_index, 0)
    worktree? = worktree_enabled?(Map.get(ctx, :worktree_spec))

    phase_specs
    |> Enum.with_index()
    |> Enum.drop(start_index)
    |> Enum.reduce_while({:ok, []}, fn {phase_spec, index}, {:ok, acc} ->
      case lower_phase(phase_spec, index, run_id, worktree? and index == start_index) do
        {:ok, steps} -> {:cont, {:ok, acc ++ steps}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, %Program{steps: steps, name: run_id}}
      {:error, %Error{}} = error -> error
    end
  end

  # The commit message `RunExecutor` has always used for a phase's commit —
  # one definition, shared with the pause path that commits partial work
  # outside the engine.
  @spec commit_message(String.t(), pos_integer()) :: String.t()
  def commit_message(run_id, phase_number), do: "Foreman run #{run_id} phase #{phase_number}"

  defp worktree_enabled?(%{enabled: false}), do: false
  defp worktree_enabled?(_spec), do: true

  defp lower_phase(phase_spec, index, run_id, first_with_worktree?) do
    number = PhaseSpec.number(phase_spec, index)

    with {:ok, agent_step} <- agent_step(phase_spec, index, number) do
      worktree = if first_with_worktree?, do: [worktree_step(index, number)], else: []

      steps =
        (worktree ++ [agent_step] ++ gate_step(phase_spec, index, number) ++ [commit_step(phase_spec, index, number, run_id)])
        |> mark_uninterruptible()

      {:ok, steps}
    end
  end

  # Only a phase's first step may be preceded by an intent check.
  defp mark_uninterruptible([first | rest]) do
    [first | Enum.map(rest, fn %Step{opts: opts} = step -> %Step{step | opts: Map.put(opts, :uninterruptible, true)} end)]
  end

  defp worktree_step(index, number) do
    %Step{kind: :worktree, id: "phase:#{number}:worktree", opts: %{phase_idx: index}}
  end

  defp agent_step(phase_spec, index, number) do
    case Map.get(phase_spec, :action) do
      :bash ->
        refuse(phase_spec, index, {:unsupported_phase_action, :bash}, "bash phases are not supported")

      :command ->
        command = Map.get(phase_spec, :command)

        if is_binary(command) and command != "" do
          {:ok, build_agent_step(phase_spec, index, number, command)}
        else
          refuse(phase_spec, index, {:invalid_phase_command, Map.get(phase_spec, :name) || ""}, "command phase has no command")
        end

      _prompt ->
        {:ok, build_agent_step(phase_spec, index, number, Map.get(phase_spec, :prompt) || "")}
    end
  end

  defp build_agent_step(phase_spec, index, number, prompt) do
    %Step{
      kind: :agent,
      id: "phase:#{number}:agent",
      opts: %{
        phase_idx: index,
        phase: Map.get(phase_spec, :name),
        runner: Overwatch,
        agent: phase_agent(phase_spec),
        # Informational only: the runner dispatches from the `launch` the
        # observer builds when the step starts, which renders the real prompt
        # (catalog prompt body or command template) from run state.
        prompt: prompt,
        max_iterations: 1,
        completion_signals: []
      }
    }
  end

  defp refuse(phase_spec, index, reason, message) do
    {:error, Error.new(:unsupported_phase_action, message, %{index: index, phase: Map.get(phase_spec, :name), reason: reason})}
  end

  # The runner dispatches from the observer's `launch`, so this agent is
  # descriptive. A provider name is mapped onto the canonical list rather
  # than converted with `String.to_atom/1` — manifest text never mints atoms.
  defp phase_agent(phase_spec) do
    declared = to_string(Map.get(phase_spec, :provider) || "claude")
    providers = ForemanServer.AgentRuntime.JidoHarness.providers()
    provider = Enum.find(providers, declared, &(Atom.to_string(&1) == declared))
    model = phase_spec |> Map.get(:models, %{}) |> Map.get("default")

    %Agent{provider: provider, model: model}
  end

  defp gate_step(phase_spec, index, number) do
    case Map.get(phase_spec, :required_file) do
      nil -> []
      key -> [%Step{kind: :gate, id: "phase:#{number}:gate", opts: %{phase_idx: index, key: key}}]
    end
  end

  defp commit_step(phase_spec, index, number, run_id) do
    %Step{
      kind: :commit,
      id: "phase:#{number}:commit",
      opts: %{
        phase_idx: index,
        message: commit_message(run_id, number),
        defer?: Map.get(phase_spec, :commit) == false
      }
    }
  end
end
