defmodule ForemanServer.AgentRuntime.JidoHarness.RunResult do
  @moduledoc """
  Normalizes a terminal `Jido.Harness.RunResult` into the
  `ForemanServer.AgentRuntime.BackendAdapter.execute_result()` shape.

  TRD-2026-8a1f3c2e / TRD-002 (RunResult normalization + error code mapping).

  Upstream `Jido.Harness.RunResult` carries a `status` enum of
  `:completed | :failed | :cancelled` and a free-form `error` field
  (`Zoi.any() |> Zoi.nullish()`). This module collapses that surface
  into the two-tuple contract every `BackendAdapter` must satisfy.

  ## Mapping

      status: :completed, error: nil            -> {:ok, run_result.text, %{provider: provider, adapter: :jido_harness}}
      error: any non-nil term                   -> ErrorCodes.map(run_result.error)
      error: nil, status: :cancelled            -> {:error, :cancelled}
      error: nil, status: :failed               -> {:error, :failed_without_detail}
      error: nil, status: any other             -> {:error, {:other, status}}

  For a successful run the metadata map's `adapter: :jido_harness` key
  lets the router, telemetry, and failure-policy code paths distinguish
  this backend from CLI-style adapters without re-deriving the identity
  from the `provider` atom. The bounded `run_result.text` is forwarded
  verbatim and may be the empty string; downstream consumers that need
  truncation awareness inspect `run_result.text_truncated?` directly
  rather than via this normalization.

  Any non-`:completed` status (`:failed`, `:cancelled`, future variants)
  is treated as an error case. A `:completed` result carrying a non-nil
  `error` is also an error case — a completed-with-error combination is
  inconsistent but we err on the side of surfacing the error rather than
  silently masking it.

  ## Why `status` participates

  The upstream `error` term is the authoritative failure detail, so an
  interpretable one always wins. When it carries no code, `status` is the
  only information left and it is NOT nothing: a `:cancelled` run was
  cancelled and a `:failed` run failed without attaching detail. Reporting
  `:unknown_error` for either made a 15-minute run's outcome
  indistinguishable from a genuinely uninterpretable payload (AGENTS.md
  §5.3). `:unknown_error` is now reachable only through `ErrorCodes.map/1`,
  for an `error` term that is malformed for its declared position —
  `RunResult.error` is documented as `nil` or a `%Jido.Harness.Error{}`,
  so a bare atom or a code-less map there is provider junk, not a reason.

  ## Example

      iex> {:ok, result} = Jido.Harness.RunResult.new(%{
      ...>   run_id: "r-1", provider: :pi, status: :completed, text: "pong"
      ...> })
      iex> ForemanServer.AgentRuntime.JidoHarness.RunResult.normalize(result)
      {:ok, "pong", %{provider: :pi, adapter: :jido_harness}}
  """

  alias ForemanServer.AgentRuntime.JidoHarness.ErrorCodes

  @typedoc """
  Successful normalization: bounded text output plus adapter metadata.
  The metadata map always carries `provider` and `adapter: :jido_harness`.
  """
  @type normalized ::
          {:ok, String.t(), %{required(:provider) => atom(), required(:adapter) => :jido_harness}}
          | ErrorCodes.code()
          | {:error, :failed_without_detail}

  @doc """
  Normalizes a `%Jido.Harness.RunResult{}` into the
  `BackendAdapter.execute_result()` shape.

  Returns `{:ok, text, %{provider: provider, adapter: :jido_harness}}`
  when `status == :completed` and `error` is `nil`. Otherwise returns
  `{:error, code}`: derived from the `error` term when that term is
  interpretable, and from `status` when it is not (see the module's
  mapping table).
  """
  @spec normalize(Jido.Harness.RunResult.t()) :: normalized()
  def normalize(%Jido.Harness.RunResult{status: :completed, error: nil} = result) do
    {:ok, result.text, %{provider: result.provider, adapter: :jido_harness}}
  end

  def normalize(%Jido.Harness.RunResult{status: status, error: error}) do
    case error_code(error) do
      {:error, _code} = err -> err
      nil -> status_code(status)
    end
  end

  # `nil` is the only term that yields no code from `ErrorCodes.map/1`;
  # every other term is delegated verbatim so an explicit error (including
  # a `%Jido.Harness.Error{}`'s category) always wins over `status`.
  defp error_code(error), do: ErrorCodes.map(error)

  # Reached only when `error` is `nil` and `status` is not `:completed`.
  defp status_code(:cancelled), do: {:error, :cancelled}
  defp status_code(:failed), do: {:error, :failed_without_detail}
  defp status_code(status) when is_atom(status), do: {:error, {:other, status}}
end
