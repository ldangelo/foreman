defmodule ForemanServer.Coordinator.Dispatch do
  @moduledoc """
  The ONE place the coordinator sends commands to `CommandGateway`.

  Every coordinator module (Runner, Executor, Reporter) dispatches through
  `system/3`, which refuses any command type outside `command_types/0`. The list
  is a compile-time constant: `merge_approve`, `run.pr.merge`,
  `project.archive`, `project.register`, `task.retry`, `run.cancel` and every
  other operator-only gate are NOT in it, so even a fully hijacked model cannot
  produce them: no action handler builds such a command and this function would
  refuse it if one did.

  `project.resume` is the one pause-state command in the list: only
  `Coordinator.Actions.ApplyRecommendation` builds it, from the fix Foreman
  itself computed for the `project.paused` setup recommendation, and only for a
  turn with operator authority.

  The coordinator acts as a system actor (`dispatch_system/2`); `task.approve`
  uses `dispatch_system_approval/2`, the same path `BeadsWatcher` uses.

  `project.repo.add` and `schedule.create` are the two operator-grade commands on
  the list: they run through `dispatch_operator/1`, i.e. the validation,
  id generation and timestamping of the CLI/HTTP verbs (repository path checks,
  `at` stamped by the gateway), never the unvalidated system path. The Executor
  only issues them for an operator turn that carries the operator's own words.
  """

  @command_types ~w(
    task.create task.approve project.update project.resume
    coordinator.append coordinator.action.record
    coordinator.turn.start coordinator.turn.complete coordinator.turn.fail
    project.repo.add schedule.create coordinator.usage.record
  )

  @operator_grade ~w(project.repo.add schedule.create)

  @type result :: {:ok, map() | nil} | {:error, term()} | {:error, term(), term()}

  @doc "Command types the coordinator may dispatch."
  @spec command_types() :: [String.t()]
  def command_types, do: @command_types

  @doc "Dispatch `command` through `gateway` (default `CommandGateway`)."
  @spec system(module(), map()) :: result()
  def system(gateway, %{type: type} = command) when is_atom(gateway) do
    cond do
      type not in @command_types ->
        {:error, {:forbidden_command, type}}

      type == "task.approve" ->
        gateway.dispatch_system_approval(command)

      type in @operator_grade ->
        gateway.dispatch_operator(command)

      true ->
        gateway.dispatch_system(command)
    end
  end
end
