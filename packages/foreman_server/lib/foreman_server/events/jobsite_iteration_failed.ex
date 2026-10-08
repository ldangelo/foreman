defmodule ForemanServer.Events.JobsiteIterationFailed do
  @moduledoc "Typed event emitted when a jobsite iteration fails."
  @enforce_keys [:jobsite_id, :index, :code, :message]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          index: pos_integer(),
          code: String.t(),
          message: String.t(),
          details: map() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :index, :code, :message, :details]
end
