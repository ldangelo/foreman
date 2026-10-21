defmodule ForemanServer.Review.PromptTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Review.{Prompt, Subject}

  defp subject(overrides \\ []) do
    struct!(
      %Subject{
        kind: :jobsite,
        subject_id: "js-1",
        project_id: "p",
        repo_path: "/repo",
        archive_dir: "/abs/archive/jobsite/js-1",
        status: "failed",
        request_title: "Fix the thing",
        request_text: "Please fix {{not_a_placeholder}} thing"
      },
      overrides
    )
  end

  test "renders absolute archive paths, request text and manifest" do
    out = Prompt.render(subject(), %{"subject_id" => "js-1", "diff_status" => "empty"})

    for name <- ~w(diff.patch changed-files.txt transcript.jsonl manifest.json) do
      assert out =~ "/abs/archive/jobsite/js-1/" <> name
    end

    assert out =~ "Fix the thing"
    assert out =~ "read-only" or out =~ "READ-ONLY"
    assert out =~ ~s("diff_status": "empty")
    refute out =~ ~r/\{\{(request_title|diff_path|manifest_json)\}\}/
  end

  test "substituted request text is not rescanned for placeholders" do
    assert Prompt.render(subject(), %{}) =~ "Please fix {{not_a_placeholder}} thing"
  end

  test "the diffs/*.patch clause appears only when the manifest lists more than one repository" do
    single = Prompt.render(subject(), %{"repositories" => [%{"id" => "main"}]})
    legacy = Prompt.render(subject(), %{})
    multi = Prompt.render(subject(), %{"repositories" => [%{"id" => "main"}, %{"id" => "b"}]})

    refute legacy =~ "diffs/"
    refute single =~ "diffs/"
    assert multi =~ "/abs/archive/jobsite/js-1/diffs/*.patch"
    assert multi =~ "also read every `diffs/*.patch`"
  end

  test "render/1 raises loudly when the manifest is missing" do
    assert_raise RuntimeError, ~r/cannot read manifest/, fn ->
      Prompt.render(subject(archive_dir: "/nonexistent/archive/dir"))
    end
  end
end
