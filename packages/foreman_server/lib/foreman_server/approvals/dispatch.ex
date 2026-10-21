defmodule ForemanServer.Approvals.Dispatch do
  @moduledoc """
  The ONE place the approvals/questions machinery sends commands to
  `CommandGateway` as a system actor.

  `system/2` refuses any command type outside `command_types/0`, a compile-time
  closed list. `merge_approve`, `run.pr.merge`, `project.archive`, `task.retry`
  and every other operator-only gate are NOT in it, so no code path here (nor a
  hijacked agent steering one) can produce them; `tool.approve` is likewise
  absent because deciding is an operator act. `question.answer` is operator-only
  too.
  """

  @command_types ~w(
    tool.request tool.deny tool.finish tool.expire
    question.open question.expire
    run.pause run.resume run.steer
  )

  @type result :: {:ok, map() | nil} | {:error, term()} | {:error, term(), term()}

  @doc "Command types this machinery may dispatch."
  @spec command_types() :: [String.t()]
  def command_types, do: @command_types

  @doc "Dispatch `command` through `gateway` (default `CommandGateway`)."
  @spec system(map(), module()) :: result()
  def system(%{type: type} = command, gateway \\ ForemanServer.CommandGateway)
      when is_atom(gateway) do
    if type in @command_types do
      gateway.dispatch_system(command)
    else
      {:error, {:forbidden_command, type}}
    end
  end
end
