defmodule ForemanServer.Events.JobsiteFailed do
  @moduledoc "Typed event emitted when a jobsite run terminates in failure."
  @enforce_keys [:jobsite_id, :code, :message]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          code: String.t(),
          message: String.t(),
          details: map() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :code, :message, :details]
end
