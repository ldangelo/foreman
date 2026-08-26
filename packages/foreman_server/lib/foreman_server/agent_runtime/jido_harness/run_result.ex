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

      status: :completed, error: nil          -> {:ok, run_result.text, %{provider: provider, adapter: :jido_harness}}
      any other state                         -> {:error, ErrorCodes.map(run_result.error)}

  For a successful run the metadata map's `adapter: :jido_harness` key
  lets the router, telemetry, and failure-policy code paths distinguish
  this backend from CLI-style adapters without re-deriving the identity
  from the `provider` atom. The bounded `run_result.text` is forwarded
  verbatim and may be the empty string; downstream consumers that need
  truncation awareness inspect `run_result.text_truncated?` directly
  rather than via this normalization.

  Any non-`:completed` status (`:failed`, `:cancelled`, future variants)
  is treated as an error case and the upstream `error` term is delegated
  to `ForemanServer.AgentRuntime.JidoHarness.ErrorCodes.map/1`. A
  `:completed` result carrying a non-nil `error` is also an error case —
  a completed-with-error combination is inconsistent but we err on the
  side of surfacing the error rather than silently masking it.

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

  @doc """
  Normalizes a `%Jido.Harness.RunResult{}` into the
  `BackendAdapter.execute_result()` shape.

  Returns `{:ok, text, %{provider: provider, adapter: :jido_harness}}`
  when `status == :completed` and `error` is `nil`. Returns
  `{:error, code}` (delegating to `ErrorCodes.map/1` on
  `run_result.error`) for any other combination.
  """
  @spec normalize(Jido.Harness.RunResult.t()) :: normalized()
  def normalize(%Jido.Harness.RunResult{status: :completed, error: nil} = result) do
    {:ok, result.text, %{provider: result.provider, adapter: :jido_harness}}
  end

  def normalize(%Jido.Harness.RunResult{error: error}) do
    # ErrorCodes.map/1 already wraps known codes as {:error, code};
    # we pass that wrapper through unchanged (no double-wrapping).
    # nil from ErrorCodes.map/1 only happens when error is nil, which
    # is the defensive case for a non-completed result carrying no
    # error — fall back to :unknown_error so the caller always sees a
    # valid `{:error, atom}` tuple.
    case ErrorCodes.map(error) do
      {:error, _code} = err -> err
      nil -> {:error, :unknown_error}
    end
  end
end
