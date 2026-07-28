defmodule ForemanServer.Events.IntegrationSyncCompleted do
  @enforce_keys [:dedupe_key]
  @type t :: %__MODULE__{
    dedupe_key: String.t()
  }
  @derive Jason.Encoder
  defstruct [:dedupe_key]
end
