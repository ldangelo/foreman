defmodule ForemanServer.AgentRuntime.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.Capabilities

  @valid %{
    type: :cli,
    strengths: [:code_generation],
    weaknesses: [:long_context],
    supported_contexts: [:refactor, :explain]
  }

  describe "validate/1 — happy path" do
    test "accepts a map with all required fields and no optional fields" do
      assert {:ok, caps} = Capabilities.validate(@valid)
      assert caps == @valid
    end

    test "accepts a map with all required fields and valid optional fields" do
      caps =
        Map.merge(@valid, %{
          cost_per_call: 0.05,
          typical_latency_ms: 1500
        })

      assert {:ok, validated} = Capabilities.validate(caps)
      assert validated == caps
    end

    test "normalizes integer cost_per_call to float" do
      caps = Map.put(@valid, :cost_per_call, 1)
      assert {:ok, validated} = Capabilities.validate(caps)
      assert validated.cost_per_call === 1.0
    end

    test "accepts a map with non-atom-free list elements as invalid (atom-list invariant)" do
      caps = Map.put(@valid, :strengths, [:atom_ok, "string_not_ok"])
      assert {:error, {:invalid_field, :strengths, :wrong_type}} = Capabilities.validate(caps)
    end
  end

  describe "validate/1 — required field missing" do
    for field <- [:type, :strengths, :weaknesses, :supported_contexts] do
      test "returns {:missing_field, #{inspect(field)}} when #{field} is absent" do
        caps = Map.delete(@valid, unquote(field))
        assert {:error, {:missing_field, unquote(field)}} = Capabilities.validate(caps)
      end
    end
  end

  describe "validate/1 — wrong type" do
    test ":type must be an atom" do
      caps = Map.put(@valid, :type, "cli")
      assert {:error, {:invalid_field, :type, :wrong_type}} = Capabilities.validate(caps)
    end

    test ":strengths must be a list" do
      caps = Map.put(@valid, :strengths, :not_a_list)
      assert {:error, {:invalid_field, :strengths, :wrong_type}} = Capabilities.validate(caps)
    end

    test ":strengths elements must all be atoms" do
      caps = Map.put(@valid, :strengths, [:code, "low_cost"])
      assert {:error, {:invalid_field, :strengths, :wrong_type}} = Capabilities.validate(caps)
    end

    test ":weaknesses must be a list" do
      caps = Map.put(@valid, :weaknesses, %{not: "a list"})
      assert {:error, {:invalid_field, :weaknesses, :wrong_type}} = Capabilities.validate(caps)
    end

    test ":weaknesses elements must all be atoms" do
      caps = Map.put(@valid, :weaknesses, [:high_latency, 42])
      assert {:error, {:invalid_field, :weaknesses, :wrong_type}} = Capabilities.validate(caps)
    end

    test ":supported_contexts must be a list" do
      caps = Map.put(@valid, :supported_contexts, "refactor,explain")

      assert {:error, {:invalid_field, :supported_contexts, :wrong_type}} =
               Capabilities.validate(caps)
    end

    test ":supported_contexts elements must all be atoms" do
      caps = Map.put(@valid, :supported_contexts, [:code, "review"])

      assert {:error, {:invalid_field, :supported_contexts, :wrong_type}} =
               Capabilities.validate(caps)
    end

    test ":cost_per_call must be a number when present" do
      caps = Map.put(@valid, :cost_per_call, "cheap")

      assert {:error, {:invalid_field, :cost_per_call, :wrong_type}} =
               Capabilities.validate(caps)
    end

    test ":typical_latency_ms must be a non-negative integer when present" do
      caps = Map.put(@valid, :typical_latency_ms, 1.5)

      assert {:error, {:invalid_field, :typical_latency_ms, :wrong_type}} =
               Capabilities.validate(caps)
    end

    test ":typical_latency_ms rejects negative integers" do
      caps = Map.put(@valid, :typical_latency_ms, -10)

      assert {:error, {:invalid_field, :typical_latency_ms, :wrong_type}} =
               Capabilities.validate(caps)
    end
  end

  describe "validate/1 — unknown field" do
    test "rejects a map with a field outside the schema" do
      caps = Map.put(@valid, :rogue_field, 1)
      assert {:error, {:unknown_field, :rogue_field}} = Capabilities.validate(caps)
    end
  end

  describe "validate/1 — root input shape" do
    test "rejects non-map input" do
      assert {:error, {:invalid_field, :root, :wrong_type}} = Capabilities.validate(:not_a_map)
    end

    test "rejects nil input" do
      assert {:error, {:invalid_field, :root, :wrong_type}} = Capabilities.validate(nil)
    end
  end

  describe "schema introspection" do
    test "required_fields/0 returns the four required fields" do
      assert Capabilities.required_fields() == [
               :type,
               :strengths,
               :weaknesses,
               :supported_contexts
             ]
    end

    test "optional_fields/0 returns the two optional fields" do
      assert Capabilities.optional_fields() == [:cost_per_call, :typical_latency_ms]
    end
  end
end
