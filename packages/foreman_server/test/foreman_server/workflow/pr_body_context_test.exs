defmodule ForemanServer.Workflow.PrBodyContextTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectSettings
  alias ForemanServer.Workflow.PrBodyContext

  @context %{run_id: "run-1", base_branch: "main"}

  describe "put_headings/2" do
    test "puts the headings the project requires into the context" do
      settings = %ProjectSettings{pr_body_headings: ["## Summary", "## Testing"]}

      assert %{pr_body_headings: ["## Summary", "## Testing"]} =
               PrBodyContext.put_headings(@context, settings)
    end

    test "omits the key when the project requires no headings" do
      assert %{} =
               Map.take(PrBodyContext.put_headings(@context, %ProjectSettings{}), [
                 :pr_body_headings
               ])
    end

    test "omits the key when the settings are absent" do
      assert %{} = Map.take(PrBodyContext.put_headings(@context, nil), [:pr_body_headings])
    end

    test "forwards a value that is not a list unchanged, so the PR builder refuses it" do
      settings = %ProjectSettings{pr_body_headings: "## Summary"}

      assert %{pr_body_headings: "## Summary"} = PrBodyContext.put_headings(@context, settings)
    end
  end

  describe "put_project_headings/2" do
    test "keeps the context unchanged for a project the projection does not know" do
      assert %{} =
               Map.take(
                 PrBodyContext.put_project_headings(@context, "project-unknown"),
                 [:pr_body_headings]
               )
    end

    test "keeps the context unchanged when the run has no project" do
      assert %{} =
               Map.take(PrBodyContext.put_project_headings(@context, nil), [:pr_body_headings])
    end
  end
end
