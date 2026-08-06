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
    unknown_keys = Map.keys(context) -- @context_keys

    if unknown_keys != [] do
      raise ArgumentError,
            "unknown ProviderError.context keys: #{inspect(unknown_keys)}; " <>
              "allowed: #{inspect(@context_keys)}"
    end

    context
    |> Map.put_new(:sanitized?, true)
    |> Map.put_new(:redacted_fields, [])
    |> Map.put_new(:missing_fields, [])
  end
end
