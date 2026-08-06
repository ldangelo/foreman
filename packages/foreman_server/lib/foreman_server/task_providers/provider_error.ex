defmodule ForemanServer.TaskProviders.ProviderError do
  @moduledoc "Typed provider error returned by task providers."

  @context_keys [
    :id,
    :command,
    :exit_code,
    :stderr_byte_count,
    :sanitized?,
    :redacted_fields,
    :missing_fields
  ]

  @enforce_keys [:code, :message, :hint, :retryable?, :context]
  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          hint: String.t() | nil,
          retryable?: boolean(),
          context: map()
        }
  @derive Jason.Encoder
  defstruct [:code, :message, :hint, :retryable?, context: %{}]

  def new(code, message, opts \\ []) when is_binary(code) and is_binary(message) do
    %__MODULE__{
      code: code,
      message: message,
      hint: Keyword.get(opts, :hint),
      retryable?: Keyword.get(opts, :retryable?, false),
      context: build_context(Keyword.get(opts, :context, %{}))
    }
  end

  defp build_context(context) when is_map(context) do
    Map.take(context, @context_keys)
  end
end
