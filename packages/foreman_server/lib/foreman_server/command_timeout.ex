defmodule ForemanServer.CommandTimeout do
  @moduledoc """
  The failure of a command whose aggregate actor did not answer within the call timeout
  (AGENTS.md 5.1: a typed error, never a bare tuple or map).

  `CommandRouter.dispatch/2` returns it as `{:error, %CommandTimeout{}}`, so it travels through
  `CommandGateway.dispatch_system/2` and `dispatch_operator/2` like any other refusal. Before it
  existed the `GenServer.call` exit escaped and killed the process that issued the command: the
  Overwatch `Tracker` and every worker with it, the `BeadsWatcher`, a `RunExecutor` that had
  finished its last phase.

  `Overwatch.Tracker` returns the same error for a worker event it did not confirm in time
  (`aggregate_id` is the worker stream, `command_type` `"worker.record"`).

  ## The outcome is unknown

  A timeout says the actor did not answer in time, not that the command was not applied. The
  command is still in the actor's mailbox and is applied when the actor gets to it; only the
  reply is dropped. A command carries a `command_id` and an actor answers a repeated one with the
  event it already wrote, so sending the same command again is safe. Treating the timeout as a
  success is not, and neither is treating it as proof that nothing happened.
  """

  @enforce_keys [:aggregate_id, :command_type, :timeout_ms]
  @type t :: %__MODULE__{
          aggregate_id: String.t(),
          command_type: String.t() | nil,
          timeout_ms: non_neg_integer()
        }
  defstruct [:aggregate_id, :command_type, :timeout_ms]

  defimpl String.Chars do
    def to_string(%{aggregate_id: aggregate_id, command_type: command_type, timeout_ms: ms}),
      do: "#{command_type || "command"} for #{aggregate_id} timed out after #{ms}ms"
  end
end
