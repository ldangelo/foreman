defmodule ForemanServer.Agents.JidoAiRunner.Error do
  @moduledoc """
  Typed failure of `ForemanServer.Agents.JidoAiRunner.run/3`.

    * `:unknown_strategy` - the strategy atom is not `:react` or `:cot`.
    * `:strategy_failed` - the strategy ran and reported failure (model or
      transport error, cancellation, iteration cap reached without an answer).
    * `:unexpected_result_shape` - `jido_ai` returned a shape this module does
      not know how to read; `details` carries it verbatim.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: nil]

  @type code :: :unknown_strategy | :strategy_failed | :unexpected_result_shape

  @type t :: %__MODULE__{code: code(), message: String.t(), details: term()}

  @spec new(code(), String.t(), term()) :: t()
  def new(code, message, details \\ nil)
      when code in [:unknown_strategy, :strategy_failed, :unexpected_result_shape] and
             is_binary(message) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
