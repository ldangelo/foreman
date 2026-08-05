defmodule ForemanServer.Events.PhaseCompleted do
  @moduledoc "Typed event emitted when a workflow phase has completed."
  @enforce_keys [:phase_id, :run_id, :index, :artifact_path, :artifact_sha256, :artifact_bytes]
  @type t :: %__MODULE__{
          phase_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          index: pos_integer(),
          artifact_path: String.t(),
          artifact_sha256: String.t(),
          artifact_bytes: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :phase_id,
    :sequence,
    :run_id,
    :index,
    :artifact_path,
    :artifact_sha256,
    :artifact_bytes
  ]
end