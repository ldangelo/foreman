defmodule ForemanServer.Events.MigrationRecordImported do
  @enforce_keys [:import_id]
  @type t :: %__MODULE__{
    import_id: String.t(),
    record_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :import_id,
    :record_id
  ]
end
