defmodule ForemanServer.Workflow.PrBodyContextTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectionStore
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
      refute Map.has_key?(
               PrBodyContext.put_headings(@context, %ProjectSettings{}),
               :pr_body_headings
             )

      refute Map.has_key?(
               PrBodyContext.put_headings(@context, %ProjectSettings{pr_body_headings: []}),
               :pr_body_headings
             )
    end

    test "omits the key when the settings are absent" do
      assert PrBodyContext.put_headings(@context, nil) == @context
    end

    test "forwards a value that is not a list unchanged, so the PR builder refuses it" do
      settings = %ProjectSettings{pr_body_headings: "## Summary"}

      assert %{pr_body_headings: "## Summary"} = PrBodyContext.put_headings(@context, settings)
    end
  end

  describe "put_project_headings/2" do
    test "adds the headings the project requires now, read from its settings projection" do
      project_id = "project-headings-#{System.unique_integer([:positive])}"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectRegistered",
            payload: %{
              project_id: project_id,
              path: "/tmp/#{project_id}",
              pr_body_headings: ["## Summary", "## Testing"]
            }
          }
        ])

      assert %{pr_body_headings: ["## Summary", "## Testing"]} =
               PrBodyContext.put_project_headings(@context, project_id)
    end

    test "keeps the context unchanged for a project the projection does not know" do
      assert PrBodyContext.put_project_headings(@context, "project-unknown") == @context
    end

    test "keeps the context unchanged when the run has no project" do
      assert PrBodyContext.put_project_headings(@context, nil) == @context
    end
  end
end
