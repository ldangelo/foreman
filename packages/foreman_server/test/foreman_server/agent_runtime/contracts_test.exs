defmodule ForemanServer.AgentRuntime.ContractsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime
  alias ForemanServer.AgentRuntime.BackendAdapter

  # Fresh fixture modules — do NOT reuse from other test files

  defmodule ConformingAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :conforming

    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding, :reasoning],
        weaknesses: [:creativity],
        supported_contexts: [:chat, :code_completion],
        cost_per_call: 0.002,
        typical_latency_ms: 500
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: _ctx}, _opts) do
      {:ok, "echo: " <> prompt, %{adapter_internal: true}}
    end
  end

  defmodule MissingFieldAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :missing_field

    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding]
        # missing :weaknesses, :supported_contexts
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  defmodule WrongTypeAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :wrong_type

    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: "should_be_a_list",  # wrong type
        weaknesses: [],
        supported_contexts: []
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  defmodule OptionalCapAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :optional_cap

    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:analysis],
        weaknesses: [:speed],
        supported_contexts: [:analysis],
        cost_per_call: 0.005,
        typical_latency_ms: 1000
      }
    end

    @impl true
    def available?, do: false

    @impl true
    def execute(_request, _opts), do: {:error, :offline}
  end

  describe "register/1 — public contract" do
    test "returns {:ok, capability_map} where second element is exactly the validated map" do
      assert {:ok, caps} = AgentRuntime.register(ConformingAdapter)
      assert is_map(caps)
      assert caps.type == :language_model
    end

    test "register/1 and BackendAdapter.validate_capabilities/1 produce identical error reasons for the same input" do
      # Missing field
      assert AgentRuntime.register(MissingFieldAdapter) ==
             BackendAdapter.validate_capabilities(MissingFieldAdapter)

      # Wrong type
      assert AgentRuntime.register(WrongTypeAdapter) ==
             BackendAdapter.validate_capabilities(WrongTypeAdapter)
    end

    test "register/1 is referentially transparent (same input → same output across repeated calls)" do
      first_result = AgentRuntime.register(OptionalCapAdapter)
      second_result = AgentRuntime.register(OptionalCapAdapter)

      assert first_result == second_result
    end
  end

  describe "schema accessors" do
    test "required_capability_fields/0 is the canonical set" do
      assert AgentRuntime.required_capability_fields() == [
               :type,
               :strengths,
               :weaknesses,
               :supported_contexts
             ]
    end

    test "optional_capability_fields/0 lists ranking-relevant fields" do
      optional = AgentRuntime.optional_capability_fields()
      assert :cost_per_call in optional
      assert :typical_latency_ms in optional
    end
  end

  describe "BackendAdapter.execute/2 — public shape" do
    test "execute/2 returns {:ok, content, metadata} shape where metadata is a map" do
      assert {:ok, content, metadata} =
               ConformingAdapter.execute(%{prompt: "test", context: %{}}, [])

      assert is_binary(content)
      assert is_map(metadata)
    end
  end

  describe "@behaviour BackendAdapter — callback exports" do
    test "every declared callback exports when a module declares @behaviour BackendAdapter" do
      # Check that ConformingAdapter exports all four required callbacks
      assert function_exported?(ConformingAdapter, :name, 0)
      assert function_exported?(ConformingAdapter, :capabilities, 0)
      assert function_exported?(ConformingAdapter, :available?, 0)
      assert function_exported?(ConformingAdapter, :execute, 2)
    end

    test "BackendAdapter.name/0 returns an atom for a conforming adapter" do
      assert is_atom(ConformingAdapter.name())
      assert ConformingAdapter.name() == :conforming
    end
  end
end
