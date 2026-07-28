defmodule ForemanServer.Events.IntegrationCommandIngested do
  @enforce_keys [:dedupe_key]
  @type t :: %__MODULE__{
    dedupe_key: String.t(),
    config: map() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :dedupe_key,
    :config
  ]
end
