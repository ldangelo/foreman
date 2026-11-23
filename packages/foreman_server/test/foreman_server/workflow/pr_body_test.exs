defmodule ForemanServer.Workflow.PrBodyTest do
  @moduledoc """
  The `## PR body` section of a phase artifact is the PR body verbatim; anything
  else is `:absent` so the caller keeps its generated template (AGENTS.md §5.3:
  absent artifact and unreadable artifact are distinct reasons).
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PrBody

  defp read(contents) do
    path = Path.join(System.tmp_dir!(), "pr_body_#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    PrBody.from_artifact(path, "test")
  end

  test "section is taken verbatim, trimmed at both ends" do
    assert {:ok, "Ships thing.\n\n### Risk\n\nLow."} =
             read("# Report\n\n## PR body\n\nShips thing.\n\n### Risk\n\nLow.\n\n")
  end

  test "ends at the next level-2 heading" do
    assert {:ok, "Only this."} = read("## PR body\n\nOnly this.\n\n## Verification\n\nNot this.\n")
  end

  test "ends at end of file" do
    assert {:ok, "Only this."} = read("## PR body\n\nOnly this.")
  end

  test "a level-3 or level-1 heading does not end the section" do
    assert {:ok, "a\n\n### sub\n\nb"} = read("## PR body\n\na\n\n### sub\n\nb\n")
    assert {:ok, "a\n\n# top\n\nb"} = read("## PR body\n\na\n\n# top\n\nb\n")
  end

  test "fenced headings are inert" do
    assert :absent = read("````\n## PR body\n\nfenced\n````\n")
    assert {:ok, "real"} = read("```\n## PR body\n\nfake\n```\n\n## PR body\n\nreal\n")
  end

  test "an indented heading is not a heading" do
    assert :absent = read("   ## PR body\n\nindented\n")
  end

  test "repeated heading is ambiguous, not chosen" do
    assert :absent = read("## PR body\n\nfirst\n\n## PR body\n\nsecond\n")
  end

  test "empty section is absent" do
    assert :absent = read("## PR body\n\n \n")
    assert :absent = read("## PR body\n")
  end

  test "over-long section is absent, with its size" do
    contents = "## PR body\n\n" <> String.duplicate("a", 65_537)
    assert {:absent, {:too_large, n}} = read(contents)
    assert n == byte_size(contents)
  end

  test "binary content is absent" do
    assert {:absent, {:not_utf8, _}} = read("## PR body\n\n\xFF\xFE bad\n")
    assert {:absent, {:contains_null, _}} = read("## PR body\n\nnul\x00byte\n")
  end

  test "absent path is absent with a reason" do
    assert {:absent, :no_artifact} = PrBody.from_artifact(nil, "test")
    assert {:absent, {:unreadable, _}} = PrBody.from_artifact("/nonexistent/artifact.md", "test")
  end
end
