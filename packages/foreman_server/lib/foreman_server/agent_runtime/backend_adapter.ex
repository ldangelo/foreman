defmodule ForemanServer.AgentRuntime.BackendAdapter do
  @moduledoc """
  TRD-2026-6af02293 §Public Contracts: behaviour for OTP-supervised agent
  runtime backend adapters.

  Every adapter module MUST implement the four callbacks below. Adapters
  register with `ForemanServer.AgentRuntime.register/1` which validates
  the returned capability map and rejects modules that omit or mistype
  any required field.

  ## Example

      defmodule MyAdapter do
        @behaviour ForemanServer.AgentRuntime.BackendAdapter

        @impl true
        def name, do: :my_adapter

        @impl true
        def capabilities do
          %{
            type: :cli,
            strengths: [:code_generation],
            weaknesses: [:long_context],
            supported_contexts: [:refactor, :explain]
          }
        end

        @impl true
        def available?, do: System.find_executable("my-tool") != nil

        @impl true
        def execute(%{prompt: prompt, context: ctx}, _opts) do
          ...
        end
      end
  """

  alias ForemanServer.AgentRuntime.Capabilities

  @typedoc "Adapter execution request passed to `execute/2`."
  @type request :: %{required(:prompt) => String.t(), required(:context) => map()}

  @typedoc "Adapter execution return: backend-agnostic text output and optional adapter-private metadata."
  @type execute_result :: {:ok, String.t(), map()} | {:error, term()}

  @typedoc """
  Raw capability map returned by an adapter's `capabilities/0` callback.
  The shape declares the four required fields and the two optional
  ranking fields. Inner types are intentionally permissive so the
  validator (see `ForemanServer.AgentRuntime.Capabilities.validate/1`)
  can surface field-specific errors instead of a dialyzer warning.
  """
  @type capabilities :: Capabilities.input()

  @doc """
  Stable, module-unique backend identifier used for routing, telemetry
  metadata, and the failure policy machinery. MUST return an atom.
  """
  @callback name() :: atom()

  @doc """
  Returns the capability map. Required fields are `type`, `strengths`,
  `weaknesses`, and `supported_contexts`. Optional fields are
  `cost_per_call` and `typical_latency_ms` for ranking. The map is
  validated by `ForemanServer.AgentRuntime.Capabilities.validate/1` at
  registration time and is never inserted into the catalog if invalid.
  """
  @callback capabilities() :: capabilities()

  @doc """
  Whether the adapter is currently usable. Local adapters typically
  inspect an executable path; remote adapters validate locally available,
  parseable credentials without a live network call.
  """
  @callback available?() :: boolean()

  @doc """
  Synchronously execute the request. The Invocation process owns timeout
  enforcement and adapter termination (see TRD §Pi Process Protocol and
  Timeout Ownership for the PiAdapter case). The adapter MUST return
  `{:ok, output, metadata}` for a successful execution or
  `{:error, reason}` otherwise. Adapter-private metadata MUST NOT include
  the backend name — the public facade strips it before returning.
  """
  @callback execute(request(), keyword()) :: execute_result()

  @doc """
  Validate the capability map returned by `caller`'s `capabilities/0`.
  Returns `{:ok, validated_caps}` or `{:error, reason}` with a
  field-specific reason. Does not mutate any state.
  """
  @spec validate_capabilities(module()) :: {:ok, capabilities()} | {:error, term()}
  def validate_capabilities(caller) do
    Capabilities.validate(caller.capabilities())
  end
end
