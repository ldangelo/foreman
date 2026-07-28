defmodule ForemanServer.Events.AttachUnsupported do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    worker_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    worker_id: "default"
  ]
end
