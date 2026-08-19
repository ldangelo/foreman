defmodule ForemanServer.Workflow.HotLoadIntegrationTest do
  @moduledoc """
  HLW-T005 / TRD-095 — hot-load integration tests.
  Valid YAML workflow, valid Elixir DSL workflow, invalid workflow rejection.
  """
  use ExUnit.Case, async: true
  @moduletag :integration
  alias ForemanServer.Workflow.{Loader, Validator}

  setup do
    # priv/workflows is the Loader's source dir; create it if absent for file-write tests.
    File.mkdir_p!("priv/workflows")
    on_exit(fn -> File.rm_rf("priv/workflows") end)
  end
  describe "Loader.load_all/0" do
    test "returns a list of loaded workflow descriptors" do
      assert is_list(Loader.load_all())
    end
  end

  describe "Loader.load_file/1 — YAML" do
    test "returns {:ok, %{path:, format: :yaml, content:}}" do
      yaml = """
      workflow:
        id: test-workflow
        name: Test
        version: "1.0.0"
        steps:
          - name: create-prd
            skill: create-prd
      """

      name = "hot-yaml-#{System.unique_integer()}.yaml"
      path = Path.join("priv/workflows", name)
      File.write!(path, yaml)

      try do
        assert {:ok, %{path: ^path, format: :yaml, content: ^yaml}} =
                 Loader.load_file(name)
      after
        File.rm!(path)
      end
    end

    test "returns {:ok, %{format: :elixir_dsl}} for .ex files" do
      elixir = "defmodule MyApp.Workflows.Test do end"

      name = "hot-ex-#{System.unique_integer()}.ex"
      path = Path.join("priv/workflows", name)
      File.write!(path, elixir)

      try do
        assert {:ok, %{path: ^path, format: :elixir_dsl, content: ^elixir}} =
                 Loader.load_file(name)
      after
        File.rm!(path)
      end
    end

    test "returns nil for unknown extensions" do
      assert is_nil(Loader.load_file("test.txt"))
      assert is_nil(Loader.load_file("test.md"))
    end
  end

  describe "Validator.validate/1 — valid workflows" do
    test "passes a minimal valid workflow" do
      workflow = %{
        id: "my-workflow",
        steps: [
          %{name: "step1", skill: "create-prd"},
          %{name: "step2", skill: "implement-trd"}
        ]
      }

      assert :ok = Validator.validate(workflow)
    end

    test "passes a workflow with all optional step fields" do
      workflow = %{
        id: "full-workflow",
        version: "1.0.0",
        steps: [
          %{
            name: "create",
            skill: "create-prd",
            idempotency_key: "my-key",
            timeout_ms: 300_000,
            on_failure: :halt,
            inputs: %{arg1: "value1"}
          }
        ]
      }

      assert :ok = Validator.validate(workflow)
    end
  end

  describe "Validator.validate/1 — invalid workflows" do
    test "rejects workflow missing id" do
      assert {:error, :missing_id} =
               Validator.validate(%{steps: [%{name: "s", skill: "create-prd"}]})
    end

    test "rejects workflow with empty steps" do
      assert {:error, :missing_steps} =
               Validator.validate(%{id: "bad", steps: []})
    end

    test "rejects step missing name" do
      assert {:error, :missing_step_name} =
               Validator.validate(%{id: "bad", steps: [%{skill: "create-prd"}]})
    end

    test "rejects step missing skill" do
      assert {:error, :missing_skill} =
               Validator.validate(%{id: "bad", steps: [%{name: "s"}]})
    end

    test "rejects step with unknown skill" do
      assert {:error, {:unknown_skill, "unknown-skill"}} =
               Validator.validate(%{id: "bad", steps: [%{name: "s", skill: "unknown-skill"}]})
    end

    test "stops at first invalid step" do
      # First step invalid → no pass-through
      assert {:error, :missing_step_name} =
               Validator.validate(%{
                 id: "bad",
                 steps: [
                   %{skill: "create-prd"},
                   %{name: "s2", skill: "create-prd"}
                 ]
               })
    end
  end
end