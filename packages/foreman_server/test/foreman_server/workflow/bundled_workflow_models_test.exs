defmodule ForemanServer.Workflow.BundledWorkflowModelsTest do
  @moduledoc """
  foreman-pv11k: bundled workflows are installed into every project by
  `foreman init --force`. A model pin that the host's pi catalog lacks fails the
  run before phase 1 with `:model_not_found`, so a pin in a bundled workflow is
  a deliberate, reviewed act and not a default.

  The only pins this repo ships are the entries of `@allowed_pins` below: the
  `fix` workflow plans on a strong model and implements on a fast one, both
  served by the operator's LiteLLM proxy through the pi harness. Every other
  bundled phase has no `models:` block, so `RunExecutor.phase_model/2` falls
  through to the project's `thread_model`, then to the provider's own default.
  Adding a pin means adding it to `@allowed_pins` on purpose.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.Interpreter

  @root Application.app_dir(:foreman_server, "priv/defaults/workflows")

  # {workflow file, phase name} => the one model that phase may pin.
  @allowed_pins %{
    {"fix.yaml", "plan"} => "litellm-stack/anthropic/claude-opus-5",
    {"fix.yaml", "fix"} => "litellm-stack/qwen-flash-next"
  }

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

  test "bundled workflow phases pin exactly the allowed models and no others" do
    pinned =
      for {file, %{"models" => models} = p} <- bundled_phases(),
          into: %{},
          do: {{file, p["name"]}, models["default"]}

    assert pinned == @allowed_pins,
           "bundled workflows must defer to the project's/provider's configured model " <>
             "except for the allowed pins; got: " <> inspect(pinned)
  end

  test "no bundled workflow mentions litellm-stack outside comments except the allowed pins" do
    allowed = Map.values(@allowed_pins)

    offenders =
      for file <- File.ls!(@root),
          String.ends_with?(file, ".yaml"),
          line <- @root |> Path.join(file) |> File.read!() |> String.split("\n"),
          not String.starts_with?(String.trim_leading(line), "#"),
          String.contains?(line, "litellm-stack"),
          not Enum.any?(allowed, &String.contains?(line, &1)),
          do: {file, line}

    assert offenders == []
  end
end
