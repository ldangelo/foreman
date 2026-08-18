defmodule ForemanServer.Actions.ReadPromptActionTest do
  @moduledoc """
  Tests for `ForemanServer.Actions.ReadPromptAction` — a Jido.Action
  that reuses `ForemanServer.Workflow.Catalog.read_prompt/1` for
  prompt-template loading (TRD-2026-4212be7e, JAF-T004).

  The TRD calls this a `Jido.Character` prompt template loader, but
  the upstream `jido` package currently exposes no `Jido.Character`
  or prompt-template API. Foreman already has prompt-body loading
  and hot-reload via `ForemanServer.Workflow.Catalog.read_prompt/1`.
  This action is the Jido.Action façade over that existing loader —
  no new prompt infrastructure is invented.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Actions.ReadPromptAction

  describe "contract" do
    test "module uses Jido.Action and exposes callbacks" do
      behaviours =
        ReadPromptAction.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Action in behaviours
      assert function_exported?(ReadPromptAction, :run, 2)
    end
  end

  describe "validate_params/1" do
    test "requires path: string" do
      assert {:ok, _} = ReadPromptAction.validate_params(%{path: "/tmp/prompt.md"})
      assert {:error, _} = ReadPromptAction.validate_params(%{})
      assert {:error, _} = ReadPromptAction.validate_params(%{path: 123})
    end
  end

  describe "run/2 (delegates to Workflow.Catalog.read_prompt/1)" do
    test "returns {:ok, %{text: text}} when Catalog returns {:ok, text}" do
      # We don't want the real Catalog or a real file in this test;
      # JAF-T004's contract is the delegation. We inject a stub
      # module via opts so the action can call catalog.read_prompt/1.
      stub = fn path ->
        assert path == "/tmp/prompt.md"
        {:ok, "# Prompt\n\nYou are helpful."}
      end

      assert {:ok, %{text: text}} =
               ReadPromptAction.run(%{path: "/tmp/prompt.md"}, %{catalog_reader: stub})

      assert text =~ "You are helpful"
    end

    test "passes through {:error, reason} from the Catalog" do
      stub = fn _path -> {:error, :prompt_not_tracked} end
      assert {:error, :prompt_not_tracked} =
               ReadPromptAction.run(%{path: "/tmp/missing.md"}, %{catalog_reader: stub})
    end
  end
end
