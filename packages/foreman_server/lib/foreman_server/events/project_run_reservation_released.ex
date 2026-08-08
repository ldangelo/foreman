defmodule ForemanServer.Events.ProjectRunReservationReleased do
  @moduledoc "Typed event emitted when a project releases a reserved run slot."
  @enforce_keys [:project_id, :run_id, :sequence]
  @type t :: %__MODULE__{
          project_id: String.t(),
          run_id: String.t(),
          sequence: integer(),
          reason: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:project_id, :run_id, :sequence, :reason]
end
