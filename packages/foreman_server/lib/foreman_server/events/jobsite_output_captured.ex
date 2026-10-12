defmodule ForemanServer.Events.JobsiteOutputCaptured do
  @moduledoc "Typed event emitted when a jobsite run's structured output is captured."
  @enforce_keys [:jobsite_id, :tag, :value]
  @type t :: %__MODULE__{jobsite_id: String.t(), tag: String.t(), value: term()}
  @derive Jason.Encoder
  defstruct [:jobsite_id, :tag, :value]
end
