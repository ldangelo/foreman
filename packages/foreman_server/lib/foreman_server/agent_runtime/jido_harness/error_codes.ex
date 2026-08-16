defmodule ForemanServer.AgentRuntime.JidoHarness.ErrorCodes do
  @moduledoc """
  Normalizes a `Jido.Harness.RunResult.error` value into a stable
  `:foreman` error tuple suitable for `BackendAdapter.execute/2` failure
  reasons and supervisor telemetry.

  TRD-2026-8a1f3c2e / TRD-002 (RunResult normalization + error code mapping).

  The upstream `Jido.Harness.RunResult.error` field is `Zoi.any() |> Zoi.nullish()`,
  so it MAY be `nil`, a plain map with `:code`, a `%Jido.Harness.Error{}`
  struct, or some other term raised by a misbehaving provider. This module
  is defensive over every shape: unknown codes are preserved under
  `{:error, {:other, term()}}` so forward-compatible providers do not
  silently collapse to `:unknown_error`, and anything we cannot interpret
  returns `{:error, :unknown_error}`.

  Public mapping:

      nil                                      -> nil
      %{code: :tool_error}                     -> {:error, :tool_error}
      %{code: :process_terminated}             -> {:error, :process_terminated}
      %{code: :unsupported_provider}            -> {:error, :unsupported_provider}
      %{code: :timeout}                        -> {:error, :timeout}
      %{code: :cancelled}                      -> {:error, :cancelled}
      %{code: other_code}                      -> {:error, {:other, other_code}}
      %{} (no :code), struct, atom, binary...   -> {:error, :unknown_error}
  """

  @type code ::
          {:error, :tool_error}
          | {:error, :process_terminated}
          | {:error, :unsupported_provider}
          | {:error, :timeout}
          | {:error, :cancelled}
          | {:error, :unknown_error}
          | {:error, {:other, term()}}

  @known_codes %{
    tool_error: :tool_error,
    process_terminated: :process_terminated,
    unsupported_provider: :unsupported_provider,
    timeout: :timeout,
    cancelled: :cancelled
  }

  @doc """
  Maps an upstream `RunResult.error` term to a `BackendAdapter.execute/2`
  failure tuple.

  Returns `nil` for `nil` input so successful runs pass through
  unchanged. Returns `{:error, {:other, code}}` for any `:code` we do not
  recognize so a future provider can introduce a new category without
  silently degrading to `:unknown_error`. Returns `{:error, :unknown_error}`
  for anything we cannot interpret (non-maps, maps missing `:code`, structs,
  binaries, atoms outside the known set, etc.).
  """
  @spec map(term()) :: code() | nil
  def map(nil), do: nil
  def map(%{code: code}) when is_atom(code) do
    case Map.fetch(@known_codes, code) do
      {:ok, normalized} -> {:error, normalized}
      :error -> {:error, {:other, code}}
    end
  end
  def map(%{code: code}), do: {:error, {:other, code}}
  def map(_other), do: {:error, :unknown_error}
end
