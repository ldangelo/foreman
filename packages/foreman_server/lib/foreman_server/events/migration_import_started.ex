defmodule ForemanServer.Events.MigrationImportStarted do
  @enforce_keys [:import_id]
  @type t :: %__MODULE__{
    import_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:import_id]
end
