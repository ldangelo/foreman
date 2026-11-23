defmodule ForemanServer.PrBodyHeadingsSettingTest do
  @moduledoc """
  The `pr_body_headings` project setting: the markdown headings a pull request
  created by Foreman must carry, validated at the aggregate boundary (one typed
  error per mistake), stored on the project update payload, and clearable.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project
  alias ForemanServer.Aggregates.Project.Settings
  alias ForemanServer.ProjectSettings

  defp registered do
    {:ok, spec} =
      Project.handle_command(Project.initial_state(), %{
        type: "project.register",
        payload: %{project_id: "p1", path: "/tmp/p1"}
      })

    Project.apply_event(Project.initial_state(), spec)
  end

  defp update(state, payload) do
    Project.handle_command(state, %{
      type: "project.update",
      payload: Map.put(payload, :project_id, "p1")
    })
  end

  describe "the projected heading list" do
    test "a project that requires headings reports them" do
      assert {:headings, ["## Summary"]} =
               ProjectSettings.pr_body_headings(%ProjectSettings{
                 pr_body_headings: ["## Summary"]
               })
    end

    test "a project that requires none reports them as unset" do
      assert :unset = ProjectSettings.pr_body_headings(%ProjectSettings{})
      assert :unset = ProjectSettings.pr_body_headings(%ProjectSettings{pr_body_headings: []})
    end

    test "a malformed heading value is reported instead of dropped" do
      assert {:malformed, "## Summary"} =
               ProjectSettings.pr_body_headings(%ProjectSettings{pr_body_headings: "## Summary"})
    end
  end

  describe "validation" do
    test "a list of markdown headings is accepted" do
      assert {:ok, %{pr_body_headings: headings}} =
               Settings.normalize(%{
                 pr_body_headings: ["## Summary", "## Testing", "### Risk"]
               })

      assert headings == ["## Summary", "## Testing", "### Risk"]
    end

    test "a heading that is not a markdown heading is rejected" do
      assert {:error, {:pr_body_headings_entry_invalid, "Summary"}} =
               Settings.normalize(%{pr_body_headings: ["Summary"]})
    end

    test "more than ten headings are rejected with the count and the limit" do
      headings = for index <- 1..11, do: "## Heading #{index}"

      assert {:error, {:pr_body_headings_too_many, 11, 10}} =
               Settings.normalize(%{pr_body_headings: headings})
    end

    test "a value that is not a list is rejected" do
      assert {:error, {:pr_body_headings_invalid, "## Summary"}} =
               Settings.normalize(%{pr_body_headings: "## Summary"})
    end

    test "a heading longer than the entry limit is rejected" do
      heading = "## " <> String.duplicate("x", 200)

      assert {:error, {:pr_body_headings_entry_invalid, _}} =
               Settings.normalize(%{pr_body_headings: [heading]})
    end

    test "a heading carrying a control character is rejected" do
      assert {:error, {:pr_body_headings_entry_invalid, _}} =
               Settings.normalize(%{pr_body_headings: ["## Summary\n## Injected"]})
    end
  end

  describe "project update" do
    test "the headings travel on the project update payload" do
      assert {:ok, %{payload: payload}} =
               update(registered(), %{pr_body_headings: ["## Summary", "## Testing"]})

      assert payload.pr_body_headings == ["## Summary", "## Testing"]
    end

    test "the setting is clearable" do
      assert {:ok, %{payload: payload}} =
               update(registered(), %{cleared_settings: ["pr_body_headings"]})

      assert payload.cleared_settings == ["pr_body_headings"]
      refute Map.has_key?(payload, :pr_body_headings)
    end
  end
end
