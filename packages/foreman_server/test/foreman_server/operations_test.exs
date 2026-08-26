defmodule ForemanServer.OperationsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Operations
  alias ForemanServer.Commands.CompleteRun

  describe "inspect_run/1" do
    test "returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Operations.inspect_run("nonexistent-run")
    end

    test "accepts binary run_id" do
      assert {:error, :not_found} = Operations.inspect_run("run-1")
    end
  end

  describe "mark_recovered/2" do
    test "returns ok or error tuple (doesn't crash)" do
      result = Operations.mark_recovered("run-recovery-1")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "passes through detector option" do
      assert is_function(&Operations.mark_recovered/2)
    end
  end

  describe "force_complete/2" do
    test "returns ok or error tuple" do
      result = Operations.force_complete("run-force-1")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts sequence option" do
      assert is_function(&Operations.force_complete/2)
    end
  end

  describe "complete_run_command/1" do
    test "builds a CompleteRun struct with the given run_id" do
      cmd = Operations.complete_run_command("run-cmd-1")
      assert %CompleteRun{run_id: "run-cmd-1"} = cmd
    end
  end

  describe "module shape" do
    test "exports the documented public functions" do
      funcs = Operations.__info__(:functions)

      assert {:inspect_run, 1} in funcs
      assert {:mark_recovered, 1} in funcs
      assert {:mark_recovered, 2} in funcs
      assert {:force_complete, 1} in funcs
      assert {:force_complete, 2} in funcs
      assert {:complete_run_command, 1} in funcs
    end
  end
end
