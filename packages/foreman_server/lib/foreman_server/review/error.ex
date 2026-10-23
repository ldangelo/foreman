defmodule ForemanServer.Review.Error do
  @moduledoc """
  Typed error payload for every Review failure (archive, capture, analysis,
  bead sink). Mirrors `ForemanServer.Jobsite.Error`.

  `code` vocabulary: `:archive_write_failed`, `:archive_missing`,
  `:archive_malformed`, `:diff_failed`, `:evaluator_failed`,
  `:evaluator_malformed_output`, `:bead_unresolved`, `:bead_write_failed`.
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @doc """
  True when the failure is a provider condition a later attempt can clear on its own.
  Only the evaluator sets it (`details.retryable: true`), and only for a failure it has
  evidence is transient; every other error is final.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{details: %{retryable: true}}), do: true
  def retryable?(%__MODULE__{}), do: false
end
