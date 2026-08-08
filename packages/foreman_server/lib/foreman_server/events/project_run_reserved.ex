defmodule ForemanServer.Events.ProjectRunReserved do
  @moduledoc "Typed event emitted when a project reserves a run slot."
  @enforce_keys [:project_id, :run_id, :sequence, :command_id, :run_start_payload]
  @type t :: %__MODULE__{
          project_id: String.t(),
          run_id: String.t(),
          sequence: integer(),
          command_id: String.t(),
          run_start_payload: map()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :run_id, :sequence, :command_id, :run_start_payload]
end
