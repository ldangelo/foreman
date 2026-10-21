defmodule ForemanServer.Events.WorkerSessionBound do
  @moduledoc """
  Typed event emitted once per worker run, before `WorkerExited`, when the
  provider reported its own session id.

  `provider_session_id` is the PROVIDER's handle (for example the Claude CLI
  session UUID) — the value a later "continue thread" / resume needs. It is
  not `WorkerStarted.session_id`, which is a Foreman-generated handle.
  """
  @enforce_keys [:worker_id, :run_id, :provider, :provider_session_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          provider: String.t(),
          provider_session_id: String.t(),
          sequence: non_neg_integer() | nil,
          model: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :provider, :provider_session_id, :sequence, :model]
end
