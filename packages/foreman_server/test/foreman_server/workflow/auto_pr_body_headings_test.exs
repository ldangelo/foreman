defmodule ForemanServer.Workflow.AutoPRBodyHeadingsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.AutoPR

  @headings ["## Summary", "## Testing"]

  test "keeps the task body when the project requires no headings" do
    context = %{run_id: "run-1", base_branch: "main", task_title: "T", task_description: "D"}

    assert {:ok, %AutoPR.PrContent{title: "T", body: "D"}} =
             AutoPR.__pr_content_for_test__(context)
  end

  test "carries the required headings with the task and the run's commits under them" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      task_description: "D",
      pr_body_headings: @headings,
      command_runner: fn
        "git", ["log", "--format=%H%x09%s", "main..foreman/run-1/implement"], _opts ->
          {"abc1234567890def\tfeat: the change\ndef4567890abc\tdocs: the readme\n", 0}
      end
    }

    assert {:ok, %AutoPR.PrContent{title: "T", body: body}} =
             AutoPR.__pr_content_for_test__(context)

    assert body =~ "## Summary\n\nT\n\nD"
    assert body =~ "## Testing\n\n- `abc1234` feat: the change\n- `def4567` docs: the readme"
  end

  test "says so under a heading when the run's commits cannot be listed, without git's own words" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      pr_body_headings: @headings,
      command_runner: fn "git", _args, _opts -> {"fatal: bad revision", 128} end
    }

    log =
      capture_log(fn ->
        assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

        # The body is public and git's output can name host paths: the body names the
        # exit code and the server log keeps what git said.
        assert body =~
                 "## Testing\n\nForeman could not list the run's commits: git log exited with 128"

        refute body =~ "fatal: bad revision"
      end)

    assert log =~ "fatal: bad revision"
  end

  test "refuses a heading list the server does not accept" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      task_title: "T",
      pr_body_headings: ["Summary"]
    }

    assert {:error, %ForemanServer.Workflow.PrBody{reason: :invalid_headings}} =
             AutoPR.__pr_content_for_test__(context)
  end

  test "refuses a heading value that is not a list instead of ignoring it" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      task_title: "T",
      pr_body_headings: "## Summary"
    }

    assert {:error, %ForemanServer.Workflow.PrBody{reason: :invalid_headings}} =
             AutoPR.__pr_content_for_test__(context)
  end

  @tag :tmp_dir
  test "lists the commits of the head branch the artifact names, not the run's own", %{
    tmp_dir: tmp_dir
  } do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      pr_body_headings: @headings
    }

    agent = self()

    command_runner = fn
      "git", ["log", "--format=%H%x09%s", "main..skill/own-branch"], _opts ->
        send(agent, {:listed, "main..skill/own-branch"})
        {"abc1234567890def\tfeat: the change\n", 0}

      "git", _args, _opts ->
        flunk("listed the run's own branch instead of the artifact's")
    end

    artifact = Path.join(tmp_dir, "artifact.md")
    File.write!(artifact, "done\nFOREMAN_BRANCH=skill/own-branch\n")

    context = Map.merge(context, %{artifact_path: artifact, command_runner: command_runner})

    assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

    assert_received {:listed, "main..skill/own-branch"}
    assert body =~ "## Testing\n\n- `abc1234` feat: the change"
  end

  # The phase artifact is the third block under the headings. The section under it is the
  # one the untemplated body carries, rendered from the same `ReviewFindings.Context`
  # (`artifact_path`, `run_id`, `repo_root`): a context that is not threaded through to it
  # raised `BadMapError` here once `findings_section/1` took the context instead of the path.
  describe "the phase artifact under a heading" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "worktree")
      report = "docs/reports/foreman-beads:foreman:task-1/REVIEW_REPORT.md"
      artifact = Path.join(root, report)
      File.mkdir_p!(Path.dirname(artifact))
      File.write!(artifact, review_artifact([finding()]))

      context = %{
        run_id: "run-1",
        base_branch: "main",
        head_branch: "foreman/run-1/implement",
        task_title: "T",
        task_description: "D",
        pr_body_headings: ["## Summary", "## Testing", "## Risk"],
        artifact_path: artifact,
        artifact_root: root,
        command_runner: fn "git", ["log" | _rest], _opts ->
          {"abc1234567890def\tfeat: the change\n", 0}
        end
      }

      %{context: context, root: root, report: report, artifact: artifact}
    end

    test "renders the review-findings section under the heading after the commits", ctx do
      assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(ctx.context)

      assert body =~
               "## Risk\n\nArtifact: `#{ctx.report}`\n\n" <>
                 "## Review findings (the review agent's report)\n\n"

      assert body =~ "Unresolved (1):\n\n- **major** `lib/foo.ex:12` — `stale assert`\n"
    end

    test "is the section the untemplated body carries", ctx do
      untemplated = Map.drop(ctx.context, [:pr_body_headings, :task_title, :task_description])

      assert {:ok, %AutoPR.PrContent{body: untemplated_body}} =
               AutoPR.__pr_content_for_test__(untemplated)

      [_before, section] = String.split(untemplated_body, "\n## Review findings", parts: 2)

      assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(ctx.context)
      assert body =~ String.trim("## Review findings" <> section)
    end

    test "says the evidence is missing, links the report and names the run when the artifact has no block",
         ctx do
      File.write!(ctx.artifact, "# Report\n\nNo findings block here.\n")

      log =
        capture_log(fn ->
          assert {:ok, %AutoPR.PrContent{body: body}} =
                   AutoPR.__pr_content_for_test__(ctx.context)

          assert body =~
                   "The review evidence is missing: the review artifact has no findings block."

          assert body =~ "Review report: [#{ctx.report}](#{ctx.report}) (run `run-1`)."
        end)

      assert log =~ "AutoPR found no review findings block in"
    end

    test "names the artifact relative to the worktree and never carries its host path", ctx do
      assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(ctx.context)

      assert body =~ "Artifact: `#{ctx.report}`"
      refute body =~ ctx.root
    end

    test "does not name an artifact outside the worktree, and still renders its section", ctx do
      outside = Path.join([Path.dirname(ctx.root), "elsewhere", "REPORT.md"])
      File.mkdir_p!(Path.dirname(outside))
      File.write!(outside, review_artifact([]))
      context = %{ctx.context | artifact_path: outside}

      assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

      refute body =~ "Artifact:"
      refute body =~ Path.dirname(outside)
      assert body =~ "## Review findings (the review agent's report)"
      assert body =~ "The review agent reported nothing unresolved."
    end

    test "says the heading is unrecorded when the run has no artifact", ctx do
      context = Map.drop(ctx.context, [:artifact_path, :artifact_root])

      assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

      assert body =~ "## Risk\n\n_Not recorded by Foreman._"
      refute body =~ "Review findings"
    end

    test "opens the pull request with that title and body", ctx do
      assert {"T", body} = created(ctx.context)

      assert body =~ "## Summary\n\nT\n\nD"
      assert body =~ "## Testing\n\n- `abc1234` feat: the change"

      assert body =~
               "## Risk\n\nArtifact: `#{ctx.report}`\n\n" <>
                 "## Review findings (the review agent's report)"

      refute body =~ ctx.root
    end
  end

  # Opens the PR through `maybe_create_pr/1` with every external command scripted and returns
  # the `--title` and `--body` that would reach GitHub. The effect keys are global per run,
  # head and base, so each call takes its own identifiers.
  defp created(context) do
    parent = self()
    uniq = System.unique_integer([:positive])

    runner = fn
      "git", ["rev-list", "--count", _range], _opts ->
        {"1\n", 0}

      "git", ["rev-parse", "--verify", _ref], _opts ->
        {"0123456789abcdef0123456789abcdef01234567\n", 0}

      "git", ["ls-remote", "origin", _ref], _opts ->
        {"", 0}

      "git", ["push" | _rest], _opts ->
        {"", 0}

      "git", ["log" | _rest], _opts ->
        {"abc1234567890def\tfeat: the change\n", 0}

      "gh", ["pr", "list" | _rest], _opts ->
        {"[]\n", 0}

      "gh", args, _opts ->
        send(parent, {:gh_args, args})
        {"https://github.com/example/repo/pull/3\n", 0}
    end

    context =
      Map.merge(context, %{
        run_id: "run-headings-#{uniq}",
        head_branch: "foreman/headings-#{uniq}/run-#{uniq}",
        cwd: context.artifact_root,
        command_runner: runner
      })

    assert {:ok, "https://github.com/example/repo/pull/3"} = AutoPR.maybe_create_pr(context)
    assert_receive {:gh_args, args}

    {gh_arg(args, "--title"), gh_arg(args, "--body")}
  end

  # `gh pr create` takes each value as the argv element after its flag.
  defp gh_arg(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _ -> nil
    end)
  end

  defp review_artifact(findings) do
    json =
      Jason.encode!(%{
        "schema" => "foreman.review_findings/1",
        "reviewed" => true,
        "findings" => findings
      })

    "# Report\n\n<!-- FOREMAN_REVIEW_FINDINGS_START -->\n#{json}\n" <>
      "<!-- FOREMAN_REVIEW_FINDINGS_END -->\n"
  end

  defp finding do
    %{
      "severity" => "major",
      "path" => "lib/foo.ex",
      "line" => 12,
      "description" => "stale assert",
      "disposition" => "open",
      "source" => "manual-review"
    }
  end
end
