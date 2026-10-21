defmodule ForemanServer.Events.CoordinatorTurnFailed do
  @moduledoc """
  Typed event: a coordinator turn failed (provider error, malformed output,
  interruption by a restart). `unhealthy_after` is the consecutive-failure
  threshold in force when it was recorded.
  """
  @enforce_keys [:project_id, :turn_id, :attempt, :error_code, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          turn_id: String.t(),
          attempt: pos_integer(),
          error_code: String.t(),
          message: String.t() | nil,
          unhealthy_after: pos_integer() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :turn_id, :attempt, :error_code, :message, :unhealthy_after, :at]
end
