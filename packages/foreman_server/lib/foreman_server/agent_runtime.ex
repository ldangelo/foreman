defmodule ForemanServer.AgentRuntime do
  @moduledoc """
  TRD-2026-6af02293: public facade for the OTP-supervised agent runtime.

  The facade is the single entry point for callers that need a backend
  adapter executed. It owns public argument validation, exposes
  backend-agnostic result types, and never reveals a successful backend
  name in its return value (the name is recorded only in telemetry
  metadata).

  ## Public contracts (TRD §Public Contracts)

      @spec execute(String.t(), map(), keyword()) ::
              {:ok, String.t()} |
              {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout} |
              {:error, {:non_zero_exit, non_neg_integer()}} |
              {:error, :all_backends_failed, %{attempts: [attempt_result()]}} |
              {:error, term()}

  ## Scope by TRD task

    * TRD-001 (this task): types, public registration, capability
      validation gate. No supervisor, no catalog, no execution.
    * TRD-002: supervisor, catalog, invocation lifecycle.
    * TRD-003: `execute/3` implementation with manual routing.
  """

  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.AgentRuntime.Capabilities

  @type backend_name :: atom()
  @type adapter :: module()
  @type capability_map :: map()

  @type attempt_result ::
          {:ok, backend_name(), String.t(), map()}
          | {:error, backend_name(), term()}

  @type execute_result ::
          {:ok, String.t()}
          | {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout}
          | {:error, {:non_zero_exit, non_neg_integer()}}
          | {:error, :all_backends_failed, %{attempts: [attempt_result()]}}
          | {:error, term()}

  @typedoc "Public strategy atom accepted by `execute/3` (TRD-003)."
  @type strategy :: :manual | :automatic | :policy

  @doc """
  Validate an adapter module's capability map without mutating any
  state. Returns `{:ok, capabilities}` on success and a field-specific
  `{:error, reason}` on failure. This is the registration gate called by
  the supervised catalog once it is wired (TRD-002); until then it acts
  as a stand-alone validator.

  An invalid adapter is never inserted; the function is pure with
  respect to durable state.
  """
  @spec register(adapter()) :: {:ok, capability_map()} | {:error, Capabilities.error_reason()}
  def register(adapter) do
    BackendAdapter.validate_capabilities(adapter)
  end

  @doc """
  Returns the list of fields required on a capability map.
  """
  @spec required_capability_fields() :: [atom()]
  defdelegate required_capability_fields(), to: Capabilities, as: :required_fields

  @doc """
  Returns the list of optional capability fields.
  """
  @spec optional_capability_fields() :: [atom()]
  defdelegate optional_capability_fields(), to: Capabilities, as: :optional_fields
end
