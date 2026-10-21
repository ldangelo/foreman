defmodule ForemanServer.Coordinator.Error do
  @moduledoc """
  Typed error payload for coordinator turn failures. Mirrors
  `ForemanServer.Review.Error`.

  `code` vocabulary: `:agent_failed` (provider could not start or ended
  abnormally), `:agent_timeout`, `:malformed_output` (the reply had no valid
  fenced JSON block), `:context_failed`, `:interrupted` (the server stopped
  mid-turn), `:execution_failed`.
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
