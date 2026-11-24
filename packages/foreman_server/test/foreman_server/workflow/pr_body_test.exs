defmodule ForemanServer.Workflow.PrBodyTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PrBody
  alias ForemanServer.Workflow.PrBody.Sources

  @headings ["## Summary", "## Testing", "## Risk", "## How to revert", "## Directed by"]

  describe "build/2" do
    test "puts the task, the run's commits and the phase artifact under the headings" do
      sources = %Sources{
        task_title: "Add the pull-request body headings",
        task_description: "The body must carry the headings.",
        commits: {:ok, [{"0123456789abcdef0123456789abcdef01234567", "feat: add the setting"}]},
        artifact_path: "/tmp/phase-report.md",
        artifact_section: "Review findings: none"
      }

      assert {:ok, body} = PrBody.build(@headings, sources)

      assert body =~
               "## Summary\n\nAdd the pull-request body headings\n\nThe body must carry the headings."

      assert body =~ "## Testing\n\n- `0123456` feat: add the setting"
      assert body =~ "## Risk\n\nArtifact: `/tmp/phase-report.md`\n\nReview findings: none"
    end

    test "says so under a heading Foreman has no content for" do
      assert {:ok, body} = PrBody.build(@headings, %Sources{})

      assert body =~ "## Summary\n\n_Not recorded by Foreman._"
      assert body =~ "## How to revert\n\n_Not recorded by Foreman._"
    end

    test "keeps the headings in the order the project requires them" do
      assert {:ok, body} = PrBody.build(["## Risk", "## Summary"], %Sources{task_title: "T"})

      assert String.match?(body, ~r/## Risk\n\nT\n\n## Summary\n\n_Not recorded by Foreman\._/)
    end

    test "puts content beyond the last heading under the last heading" do
      sources = %Sources{
        task_title: "T",
        commits: {:ok, [{"abcdef1234567890", "fix: the thing"}]},
        artifact_path: "/tmp/artifact.md"
      }

      assert {:ok, body} = PrBody.build(["## One"], sources)

      assert body ==
               "## One\n\nT\n\n- `abcdef1` fix: the thing\n\nArtifact: `/tmp/artifact.md`"
    end

    test "refuses headings that are not markdown headings" do
      assert {:error, %PrBody{reason: :invalid_headings}} = PrBody.build(["Summary"], %Sources{})
    end

    test "refuses an empty heading list instead of returning an empty body" do
      assert {:error, %PrBody{reason: :invalid_headings}} = PrBody.build([], %Sources{})
    end

    test "refuses a body larger than the pull-request body limit" do
      sources = %Sources{task_description: String.duplicate("x", 70_000)}

      assert {:error, %PrBody{reason: :body_too_large}} = PrBody.build(["## Summary"], sources)
    end

    test "says why the run's commits are missing instead of leaving the heading empty" do
      sources = %Sources{commits: {:error, "git log exited with 128"}}

      assert {:ok, body} = PrBody.build(["## Testing"], sources)

      assert body ==
               "## Testing\n\nForeman could not list the run's commits: git log exited with 128"
    end

    test "joins the review section on one blank line, whatever newlines it arrives padded with" do
      sources = %Sources{
        artifact_path: "docs/reports/r.md",
        artifact_section: "\n## Review findings\n\nNothing unresolved.\n"
      }

      assert {:ok, body} = PrBody.build(["## Risk"], sources)

      assert body ==
               "## Risk\n\nArtifact: `docs/reports/r.md`\n\n## Review findings\n\nNothing unresolved."
    end

    test "does not count a review section that is only whitespace as content" do
      assert {:ok, body} = PrBody.build(["## Risk"], %Sources{artifact_section: "\n \n"})

      assert body == "## Risk\n\n_Not recorded by Foreman._"
    end

    test "refuses headings that are not a list instead of ignoring them" do
      assert {:error,
              %PrBody{
                reason: :invalid_headings,
                detail: {:pr_body_headings_invalid, "## Summary"}
              }} = PrBody.build("## Summary", %Sources{})
    end

    test "raises on sources that are not a `Sources` instead of calling the headings invalid" do
      not_sources = Map.new()

      assert_raise FunctionClauseError, fn -> PrBody.build(["## Summary"], not_sources) end
    end
  end
end
