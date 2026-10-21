defmodule ForemanServer.Agents.JidoAiRunner.Result do
  @moduledoc """
  Successful outcome of `ForemanServer.Agents.JidoAiRunner.run/3`.

  `usage` is the provider usage map exactly as `jido_ai` reports it
  (token counters, and `:total_cost` when the provider prices the call) or
  `nil` when the provider reported none. An absent usage is unknown, not zero.
  `trace` and `final_token` are only populated by the ReAct strategy.
  """

  @enforce_keys [:strategy, :output, :termination_reason]
  defstruct [:strategy, :output, :termination_reason, :usage, :trace, :final_token]

  @type t :: %__MODULE__{
          strategy: :react | :cot,
          output: String.t(),
          termination_reason: atom(),
          usage: map() | nil,
          trace: [map()] | nil,
          final_token: term() | nil
        }
end
