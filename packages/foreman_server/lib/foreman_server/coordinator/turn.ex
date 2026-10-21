defmodule ForemanServer.Coordinator.Turn do
  @moduledoc """
  What a coordinator agent produced for one turn: the reply text for the
  operator and the RAW actions it asked for (string-keyed JSON objects, exactly
  as decoded). Nothing here is trusted: `ForemanServer.Coordinator.Action`
  normalises each raw action and the Executor decides what actually runs.
  """
  @enforce_keys [:reply]
  @type t :: %__MODULE__{reply: String.t(), actions: [map()]}
  defstruct [:reply, actions: []]
end
