defmodule ForemanServer.Workflow.ModelResolutionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.ModelResolution

  # TRD-007-TEST / AC-006-1, AC-006-2: one documented order decides the model a
  # phase runs with, and the winner is named. The project's `thread_model` (the
  # value the calling environment supplies) only ever fills a gap.
  describe "resolve/2 precedence" do
    for {declared, project, model, source} <- [
          {"minimax/MiniMax-M2.7", "ghost/model", "minimax/MiniMax-M2.7", :phase_declared},
          {"minimax/MiniMax-M2.7", nil, "minimax/MiniMax-M2.7", :phase_declared},
          {nil, "proj/model", "proj/model", :project_thread_model},
          {nil, nil, nil, :provider_default}
        ] do
      test "declared=#{inspect(declared)} project=#{inspect(project)} -> #{source}" do
        assert %ModelResolution{model: unquote(model), source: unquote(source)} =
                 ModelResolution.resolve(unquote(declared), unquote(project))
      end
    end

    test "a declared model is never overridden by the project's, even when they differ" do
      resolution = ModelResolution.resolve("phase/model", "project/model")

      assert resolution.model == "phase/model"
      refute resolution.model == "project/model"
      assert resolution.source == :phase_declared
    end

    test "the three sources are distinct, so a record naming one never reads as another" do
      sources =
        for {declared, project} <- [{"a/b", "c/d"}, {nil, "c/d"}, {nil, nil}] do
          ModelResolution.resolve(declared, project).source
        end

      assert length(Enum.uniq(sources)) == 3
    end

    test "the struct cannot be built without both a model slot and a source" do
      assert_raise ArgumentError, fn -> struct!(ModelResolution, model: "a/b") end
    end
  end
end
