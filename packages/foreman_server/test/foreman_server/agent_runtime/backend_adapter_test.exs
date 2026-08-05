defmodule ForemanServer.AgentRuntime.BackendAdapterTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.BackendAdapter

  defmodule ConformingAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :conforming

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: [:code_generation],
        weaknesses: [:long_context],
        supported_contexts: [:refactor]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: _ctx}, _opts) do
      {:ok, "echo: " <> prompt, %{adapter_internal: true}}
    end
  end

  defmodule OptionalCapAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :optional_cap

    @impl true
    def capabilities do
      %{
        type: :remote,
        strengths: [:long_context],
        weaknesses: [:code_execution],
        supported_contexts: [:review],
        cost_per_call: 0.02,
        typical_latency_ms: 800
      }
    end

    @impl true
    def available?, do: false

    @impl true
    def execute(_request, _opts), do: {:error, :offline}
  end

  defmodule InvalidAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :invalid

    @impl true
    def capabilities do
      %{
        # missing :type
        strengths: [],
        weaknesses: [],
        supported_contexts: []
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  describe "behaviour conformance" do
    test "a module declaring @behaviour compiles when all callbacks are @impl'd" do
      # The mere fact that this test file compiles and loads is the
      # primary contract: all three fixture modules declare
      # @behaviour BackendAdapter and implement every callback.
      assert function_exported?(ConformingAdapter, :name, 0)
      assert function_exported?(ConformingAdapter, :capabilities, 0)
      assert function_exported?(ConformingAdapter, :available?, 0)
      assert function_exported?(ConformingAdapter, :execute, 2)
    end

    test "conforming adapter returns its declared name" do
      assert ConformingAdapter.name() == :conforming
    end

    test "conforming adapter returns its declared capabilities" do
      assert ConformingAdapter.capabilities().type == :cli
    end

    test "conforming adapter advertises availability" do
      assert ConformingAdapter.available?() == true
    end

    test "conforming adapter executes synchronously and returns metadata" do
      result = ConformingAdapter.execute(%{prompt: "hi", context: %{}}, [])
      assert {:ok, "echo: hi", %{adapter_internal: true}} = result
    end

    test "optional-cap adapter reports unavailable when configured so" do
      refute OptionalCapAdapter.available?()
    end
  end

  describe "validate_capabilities/1" do
    test "delegates to Capabilities.validate/1 for a conforming adapter" do
      assert {:ok, caps} = BackendAdapter.validate_capabilities(ConformingAdapter)
      assert caps.type == :cli
      assert caps.supported_contexts == [:refactor]
    end

    test "returns a field-specific error for a non-conforming adapter" do
      assert {:error, {:missing_field, :type}} =
               BackendAdapter.validate_capabilities(InvalidAdapter)
    end

    test "validates optional ranking fields when present" do
      assert {:ok, caps} = BackendAdapter.validate_capabilities(OptionalCapAdapter)
      assert caps.cost_per_call == 0.02
      assert caps.typical_latency_ms == 800
    end
  end
end
