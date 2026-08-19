defmodule ForemanServer.Workflow.ValidatorTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Workflow.Validator

  # ---------------------------------------------------------------------------
  # Valid workflows
  # ---------------------------------------------------------------------------

  describe "valid workflow" do
    test "minimal valid workflow with command" do
      wf = %{
        "name" => "test-wf",
        "phases" => [
          %{"name" => "phase-1", "command" => "/skill:ensemble-fix-issue --foreman"}
        ]
      }

      assert :ok = Validator.validate(wf)
    end

    test "valid workflow with all known skills" do
      skills = ~w[
        create-prd refine-prd create-trd refine-trd implement-trd fix-issue
        ensemble-fix-issue
        ensemble-full-create-prd ensemble-full-refine-prd
        ensemble-full-create-trd ensemble-full-create-trd-foreman
        ensemble-full-implement-trd ensemble-full-implement-trd-beads
        ensemble-full-refine-trd-foreman
      ]

      for skill <- skills do
        wf = %{
          "name" => "test",
          "phases" => [%{"name" => "p", "command" => "/skill:#{skill} --foreman"}]
        }

        assert :ok = Validator.validate(wf), "expected #{skill} to be valid"
      end
    end

    test "valid workflow with prompt instead of command" do
      wf = %{
        "name" => "prompt-wf",
        "phases" => [
          %{"name" => "ask", "prompt" => "What is the next step?"}
        ]
      }

      assert :ok = Validator.validate(wf)
    end

    test "valid workflow with bash instead of command" do
      wf = %{
        "name" => "bash-wf",
        "phases" => [
          %{"name" => "run", "bash" => "echo hello"}
        ]
      }

      assert :ok = Validator.validate(wf)
    end

    test "valid workflow with description" do
      wf = %{
        "name" => "descriptive-wf",
        "description" => "A workflow with more metadata",
        "phases" => [
          %{"name" => "phase-1", "command" => "/skill:fix-issue --foreman"}
        ]
      }

      assert :ok = Validator.validate(wf)
    end

    test "ignores command without /skill: prefix" do
      wf = %{
        "name" => "no-skill-wf",
        "phases" => [
          %{"name" => "phase-1", "command" => "just a plain command"}
        ]
      }

      assert :ok = Validator.validate(wf)
    end
  end

  # ---------------------------------------------------------------------------
  # Missing top-level keys
  # ---------------------------------------------------------------------------

  describe "missing top-level keys" do
    test "missing name" do
      wf = %{"phases" => [%{"name" => "p", "command" => "/skill:fix-issue"}]}
      assert {:error, :missing_name} = Validator.validate(wf)
    end

    test "missing phases" do
      wf = %{"name" => "no-phases"}
      assert {:error, :missing_phases} = Validator.validate(wf)
    end

    test "empty phases list" do
      wf = %{"name" => "empty", "phases" => []}
      assert {:error, :empty_phases} = Validator.validate(wf)
    end

    test "not a map" do
      assert {:error, {:invalid_workflow, :not_a_map}} = Validator.validate("string")
      assert {:error, {:invalid_workflow, :not_a_map}} = Validator.validate(nil)
      assert {:error, {:invalid_workflow, :not_a_map}} = Validator.validate([1, 2, 3])
    end
  end

  # ---------------------------------------------------------------------------
  # Phase-level validation
  # ---------------------------------------------------------------------------

  describe "phase validation" do
    test "phase missing name" do
      wf = %{
        "name" => "test",
        "phases" => [
          %{"command" => "/skill:fix-issue --foreman"}
        ]
      }

      assert {:error, {:missing_phase_name, 0}} = Validator.validate(wf)
    end

    test "phase missing action (no command, no prompt, no bash)" do
      wf = %{
        "name" => "test",
        "phases" => [
          %{"name" => "broken-phase"}
        ]
      }

      assert {:error, {:missing_phase_action, 0}} = Validator.validate(wf)
    end

    test "second phase missing name reports correct index" do
      wf = %{
        "name" => "test",
        "phases" => [
          %{"name" => "p1", "command" => "/skill:fix-issue"},
          %{"command" => "/skill:fix-issue"}
        ]
      }

      assert {:error, {:missing_phase_name, 1}} = Validator.validate(wf)
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown skill detection
  # ---------------------------------------------------------------------------

  describe "unknown skill detection" do
    test "unknown skill in command" do
      wf = %{
        "name" => "test",
        "phases" => [
          %{"name" => "p", "command" => "/skill:totally-unknown-skill --foreman"}
        ]
      }

      assert {:error, {:unknown_skill, "totally-unknown-skill"}} = Validator.validate(wf)
    end

    test "similar-but-wrong skill is rejected" do
      # "implement-trd" is known, but "implement-trd-foreman" is not (no such bundle)
      wf = %{
        "name" => "test",
        "phases" => [
          %{"name" => "p", "command" => "/skill:implement-trd-foreman --foreman"}
        ]
      }

      assert {:error, {:unknown_skill, "implement-trd-foreman"}} = Validator.validate(wf)
    end
  end
end
