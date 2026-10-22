defmodule ForemanServer.Workflow.BundledWorkflowModelsTest do
  @moduledoc """
  foreman-pv11k: bundled workflows are installed into every project by
  `foreman init --force`, so they must not pin a model that only one operator's
  proxy defines (`litellm-stack/smart_router`). A pinned model that the host's
  pi catalog lacks fails the run before phase 1 with `:model_not_found`.

  With no `models:` block, `RunExecutor.phase_model/2` falls through to the
  project's `thread_model`, then to the provider's own default.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.Interpreter

  @root Application.app_dir(:foreman_server, "priv/defaults/workflows")

  defp bundled_phases do
    for file <- @root |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")) |> Enum.sort(),
        {:ok, workflow} = Interpreter.load!(Path.join(@root, file)),
        phase <- workflow["phases"] do
      {file, phase}
    end
  end

  test "discovers bundled phases from disk" do
    assert length(bundled_phases()) > 0
  end

  test "no bundled workflow phase pins a model" do
    pinned =
      for {file, %{"models" => models} = p} <- bundled_phases(), do: {file, p["name"], models}

    assert pinned == [],
           "bundled workflows must defer to the project's/provider's configured model, got: " <>
             inspect(pinned)
  end

  test "no bundled workflow file mentions litellm-stack outside comments" do
    offenders =
      for file <- File.ls!(@root),
          String.ends_with?(file, ".yaml"),
          line <- @root |> Path.join(file) |> File.read!() |> String.split("\n"),
          not String.starts_with?(String.trim_leading(line), "#"),
          String.contains?(line, "litellm-stack"),
          do: {file, line}

    assert offenders == []
  end
end
