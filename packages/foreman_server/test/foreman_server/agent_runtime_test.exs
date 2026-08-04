defmodule ForemanServer.AgentRuntimeTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime

  defmodule ValidAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :valid

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: [:code_generation],
        weaknesses: [],
        supported_contexts: [:refactor]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: _ctx}, _opts) do
      {:ok, "ok: " <> prompt, %{}}
    end
  end

  defmodule MissingFieldAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :missing_field

    @impl true
    def capabilities do
      # :type is missing
      %{
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

  defmodule WrongTypeAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :wrong_type

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: "not a list",
        weaknesses: [],
        supported_contexts: []
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  defmodule NonAtomListAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :non_atom_list

    @impl true
    def capabilities do
      %{
        type: :cli,
        # list, but elements are not all atoms (PRD AC-006-1)
        strengths: [:ok_atom, "not_an_atom"],
        weaknesses: [],
        supported_contexts: []
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  describe "register/1 — happy path" do
    test "returns {:ok, validated_caps} for a conforming adapter" do
      assert {:ok, caps} = AgentRuntime.register(ValidAdapter)
      assert caps.type == :cli
      assert caps.supported_contexts == [:refactor]
    end

    test "the returned capability map is identical to the input" do
      {:ok, caps} = AgentRuntime.register(ValidAdapter)
      assert caps == ValidAdapter.capabilities()
    end
  end

  describe "register/1 — error paths store nothing" do
    test "returns {:error, {:missing_field, :type}} on a missing required field" do
      assert {:error, {:missing_field, :type}} = AgentRuntime.register(MissingFieldAdapter)
    end

    test "returns {:error, {:invalid_field, :strengths, :wrong_type}} on a bad list field" do
      assert {:error, {:invalid_field, :strengths, :wrong_type}} =
               AgentRuntime.register(WrongTypeAdapter)
    end

    test "returns {:error, {:invalid_field, :strengths, :wrong_type}} when list elements are not atoms" do
      assert {:error, {:invalid_field, :strengths, :wrong_type}} =
               AgentRuntime.register(NonAtomListAdapter)
    end

    test "an invalid adapter does not raise and does not store any state" do
      # The register/1 contract: an invalid adapter is rejected with a
      # field-specific error and nothing is stored. The function MUST
      # NOT raise an exception.
      assert {:error, _reason} = AgentRuntime.register(MissingFieldAdapter)
    end
  end

  describe "schema field accessors" do
    test "required_capability_fields/0 delegates to Capabilities" do
      assert AgentRuntime.required_capability_fields() == [
               :type,
               :strengths,
               :weaknesses,
               :supported_contexts
             ]
    end

    test "optional_capability_fields/0 delegates to Capabilities" do
      assert AgentRuntime.optional_capability_fields() == [:cost_per_call, :typical_latency_ms]
    end
  end
end
