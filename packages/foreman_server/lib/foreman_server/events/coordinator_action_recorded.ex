defmodule ForemanServer.Events.CoordinatorActionRecorded do
  @moduledoc """
  Typed event: the outcome of ONE coordinator action. `status` is `executed`,
  `proposed`, `rejected` or `failed`; `params` is the whitelisted, normalised
  action (never raw model output); `result_ref` carries the ids the action
  produced (`task_id`, `run_id`, `thread_id`, `memory`) so a later turn can see
  what already happened.
  """
  @enforce_keys [:project_id, :turn_id, :action_id, :kind, :status, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          turn_id: String.t(),
          action_id: String.t(),
          kind: String.t(),
          params: map(),
          status: String.t(),
          reason: String.t() | nil,
          result_ref: map() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :turn_id,
    :action_id,
    :kind,
    :status,
    :reason,
    :result_ref,
    :at,
    params: %{}
  ]
end
