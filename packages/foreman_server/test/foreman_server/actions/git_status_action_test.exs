defmodule ForemanServer.Actions.GitStatusActionTest do
  @moduledoc """
  Tests for `ForemanServer.Actions.GitStatusAction` — the first
  Foreman `Jido.Action` (TRD-2026-4212be7e, JAF-T001..T002).

  This action exposes `git status --porcelain` as a structured result
  suitable for AI tools (the "git_status" tool that the TRD's JAF-T002
  lists among the existing TypeScript tool factories to migrate).
  Because Foreman has no legacy TypeScript tool factories, this is
  the first concrete Jido.Action module — establishing the pattern
  that JAF-T002 onward will follow.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Actions.GitStatusAction

  describe "Jido.Action contract (JAF-T001)" do
    test "module uses Jido.Action and exposes the required callbacks" do
      behaviours =
        GitStatusAction.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Action in behaviours
      assert function_exported?(GitStatusAction, :run, 2)
    end

    test "name/0, description/0, category/0, vsn/0, schema/0 are exposed" do
      assert is_binary(GitStatusAction.name())
      assert is_binary(GitStatusAction.description())
      assert is_binary(GitStatusAction.category())
      assert is_binary(GitStatusAction.vsn())
      assert is_list(GitStatusAction.schema())
    end

    test "to_tool/0 returns an LLM-compatible tool description" do
      tool = GitStatusAction.to_tool()
      assert is_map(tool) or is_list(tool)
    end
  end

  describe "validate_params/1 (JAF-T003 validation middleware)" do
    test "accepts an empty map (no required params)" do
      assert {:ok, _} = GitStatusAction.validate_params(%{})
    end

    test "accepts a path: string opt" do
      assert {:ok, _} = GitStatusAction.validate_params(%{path: "/tmp"})
    end

    test "rejects non-string path" do
      assert {:error, _} = GitStatusAction.validate_params(%{path: 123})
    end
  end

  describe "run/2 (integration: shells out to git)" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "git_status_action_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "returns parsed porcelain lines for a tmp git repo", %{tmp_dir: tmp_dir} do
      _ = System.cmd("git", ["init", "-q", tmp_dir], stderr_to_stdout: true)

      assert {:ok, result} = GitStatusAction.run(%{path: tmp_dir}, %{})
      assert is_map(result)
      assert Map.has_key?(result, :porcelain) or Map.has_key?(result, :status)
    end
  end
end
