defmodule ForemanServer.Coordinator.Turn do
  @moduledoc """
  What a coordinator agent produced for one turn: the reply text for the
  operator and the RAW actions it asked for (string-keyed JSON objects, exactly
  as decoded). Nothing here is trusted: `ForemanServer.Coordinator.Action`
  normalises each raw action and the Executor decides what actually runs.

  `usage` is what the provider spent on the turn (`ForemanServer.Usage`): `nil`
  when the agent reported none (a scripted agent, a run that never started), an
  all-nil `%Usage{}` when the provider ran and reported nothing. The
  `TurnRunner` records it before the turn completes.
  """
  alias ForemanServer.Usage

  @enforce_keys [:reply]
  @type t :: %__MODULE__{reply: String.t(), actions: [map()], usage: Usage.t() | nil}
  defstruct [:reply, actions: [], usage: nil]
end
