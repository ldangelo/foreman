defmodule ForemanServer.Events.ProjectRunReserved do
  @moduledoc """
  Typed event emitted when a project reserves a run slot.

  `implementation_key` is the optional SHA-256 hex digest of
  `"<project_id> \\0 <normalized_trd_path>"` carried by the frozen
  workflow snapshot. When nonblank it identifies the single TRD being
  implemented; the project aggregate uses it to reject a concurrent
  same-key reservation while still admitting distinct keys.
  """
  @enforce_keys [:project_id, :run_id, :sequence, :command_id, :run_start_payload]
  @type t :: %__MODULE__{
          project_id: String.t(),
          run_id: String.t(),
          sequence: integer(),
          command_id: String.t(),
          run_start_payload: map(),
          implementation_key: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :run_id,
    :sequence,
    :command_id,
    :run_start_payload,
    :implementation_key
  ]
end
