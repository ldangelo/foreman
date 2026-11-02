defmodule ForemanServer.Workflow.BundledWorkflowSkillsTest do
  @moduledoc """
  Bundled workflows are installed into every project by `foreman init --force`. A
  `/skill:` name in one of them that no installed skill answers to kills the run at that
  phase, after every earlier phase has already been paid for (`prd.yaml` named
  `ensemble-refine-trd-foreman` and `implement-trd.yaml` named
  `ensemble-full-implement-trd`; neither skill exists on a host with the `ensemble-*`
  family installed). `Validator` is the one list of skill names Foreman knows, so every
  bundled manifest must pass it.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.{Interpreter, Validator}

  @root Application.app_dir(:foreman_server, "priv/defaults/workflows")

  defp bundled_workflows do
    for file <- @root |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")) |> Enum.sort() do
      {:ok, workflow} = Interpreter.load!(Path.join(@root, file))
      {file, workflow}
    end
  end

  test "every bundled workflow passes the validator" do
    failures =
      for {file, workflow} <- bundled_workflows(),
          result = Validator.validate(workflow),
          result != :ok,
          do: {file, result}

    assert failures == []
  end
end
