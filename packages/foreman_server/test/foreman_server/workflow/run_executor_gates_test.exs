defmodule ForemanServer.Workflow.RunExecutorGatesTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PlanContext

  describe "PlanContext.build/1 discrimination" do
    test "non-plan task returns {:not_applicable, %{}}" do
      assert PlanContext.build(%{task_type: "implement"}) == {:not_applicable, %{}}
      assert PlanContext.build(%{"type" => "ticket"}) == {:not_applicable, %{}}
      assert PlanContext.build(%{}) == {:not_applicable, %{}}
    end

    test "plan task without project returns explicit error" do
      assert {:error, {:project_not_found, "tf-1"}} =
               PlanContext.build(%{task_type: "plan", project_id: "tf-1", run_id: "run-abcdef"})
    end
  end

  describe "required file gate key handling" do
    test "single-segment plan context key resolves to path" do
      ctx = %{"planning" => %{"prd_path" => "/tmp/PRD-x.md"}}
      assert traverse(ctx, "planning.prd_path") == {:ok, "/tmp/PRD-x.md"}
    end

    test "three-segment path resolves with deeper nesting" do
      ctx = %{"a" => %{"b" => %{"c" => "/x"}}}
      assert traverse(ctx, "a.b.c") == {:ok, "/x"}
    end

    test "missing nested key returns unknown_key" do
      assert traverse(%{"planning" => %{}}, "planning.prd_path") ==
               {:error, {:required_file_unknown_key, "prd_path"}}
    end

    test "top-level missing key returns unknown_key" do
      assert traverse(%{}, "missing") == {:error, {:required_file_unknown_key, "missing"}}
    end

    test "non-map intermediate rejected as unknown_key" do
      assert traverse(%{"a" => "not-a-map"}, "a.b") ==
               {:error, {:required_file_unknown_key, "a"}}
    end
  end

  defp traverse(ctx, key) when is_binary(key) do
    segments = String.split(key, ".", trim: true)
    traverse(ctx, segments)
  end

  defp traverse(_ctx, []), do: {:error, :required_file_traversal_failed}

  defp traverse(ctx, [segment]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      nil -> {:error, {:required_file_unknown_key, segment}}
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, {:required_file_invalid_path, segment}}
    end
  end

  defp traverse(ctx, [segment | rest]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      %{} = next ->
        traverse(next, rest)

      _ ->
        {:error, {:required_file_unknown_key, segment}}
    end
  end
end
