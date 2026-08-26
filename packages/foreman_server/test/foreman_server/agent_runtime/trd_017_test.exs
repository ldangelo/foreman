defmodule ForemanServer.AgentRuntime.TRD017Test do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  describe "prompt_template_assigns/4" do
    defp make_state(workflow_snapshot) do
      %{
        run_id: "run-test",
        task: %{"workflow_snapshot" => workflow_snapshot},
        artifact_base: "/tmp"
      }
    end

    defp phase_spec do
      %{
        "name" => "test-phase",
        "action" => "prompt",
        "context" => %{}
      }
    end

    test "{{input.prompt}} resolves to submitted prompt" do
      state = make_state(%{"input" => %{"prompt" => "hello world"}})

      assigns = RunExecutor.prompt_template_assigns(state, phase_spec(), 1, %{})

      assert assigns["input.prompt"] == "hello world"
    end

    test "absent input block yields \"\"" do
      state = make_state(%{})

      assigns = RunExecutor.prompt_template_assigns(state, phase_spec(), 1, %{})

      assert assigns["input.prompt"] == ""
      assert assigns["input.prompt_argument"] == ""
    end

    test "unknown token is left intact" do
      state = make_state(%{"input" => %{"prompt" => "hello"}})

      assigns = RunExecutor.prompt_template_assigns(state, phase_spec(), 1, %{})

      assert Map.get(assigns, "unknown.token", "{{unknown.token}}") == "{{unknown.token}}"
    end

    test "prompt containing literal {{run_id}} is not recursively expanded" do
      state = make_state(%{"input" => %{"prompt" => "literal {{run_id}}"}})

      assigns = RunExecutor.prompt_template_assigns(state, phase_spec(), 1, %{})

      assert assigns["input.prompt"] == "literal {{run_id}}"
      assert assigns["input.prompt_argument"] == Jason.encode!("literal {{run_id}}")
    end
  end
end
