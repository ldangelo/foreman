defmodule ForemanServer.Workflow.PhasePRBodyTest do
  # `PhasePR.open_pr/1` is one of the two PR-opening paths (`AutoPR.open_pr/5`
  # is the other) that appends the unresolved-review-findings block a `review`
  # phase writes into its artifact. No real git/gh: a stubbed `command_runner`
  # drives the pipeline exactly as `PhasePR.maybe_create/1` documents it.
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PhasePR

  defp temp_artifact!(contents) do
    dir = Path.join(System.tmp_dir!(), "phase-pr-body-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "REPORT.md")
    File.write!(path, contents)
    path
  end

  defp stub_runner(test_pid) do
    fn
      "git", ["rev-list", "--count", _range], _opts ->
        {"1", 0}

      "git", ["push", "-u", "origin", _branch], _opts ->
        {"", 0}

      "gh", ["pr", "list" | _rest], _opts ->
        {"[]", 0}

      "gh", ["pr", "create" | _rest] = args, _opts ->
        send(test_pid, {:gh_pr_create_args, args})
        {"https://github.com/example/repo/pull/1", 0}
    end
  end

  defp request(artifact_path) do
    %PhasePR.Request{
      run_id: "run-1",
      phase_id: "phase-1",
      phase_index: 1,
      phase_name: "repo-rules-review",
      base_branch: "main",
      head_branch: "foreman/task-1/run-1",
      cwd: System.tmp_dir!(),
      artifact_path: artifact_path,
      command_runner: stub_runner(self())
    }
  end

  defp body_arg(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--body", body] -> body
      _ -> nil
    end)
  end

  test "the PR body carries the unresolved findings when the artifact has a block" do
    artifact =
      temp_artifact!("""
      # Report

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """)

    assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(request(artifact))

    assert_receive {:gh_pr_create_args, args}
    body = body_arg(args)

    assert body =~ "## Unresolved review findings"
    assert body =~ "lib/foo.ex:12"
  end

  test "the PR body has no findings heading when the artifact has no markers" do
    artifact = temp_artifact!("# Report\n\nNothing to report.\n")

    assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(request(artifact))

    assert_receive {:gh_pr_create_args, args}
    body = body_arg(args)

    refute body =~ "## Unresolved review findings"
  end

  test "the PR body has no findings heading when the artifact path is nil" do
    assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(request(nil))

    assert_receive {:gh_pr_create_args, args}
    body = body_arg(args)

    refute body =~ "## Unresolved review findings"
  end
end
