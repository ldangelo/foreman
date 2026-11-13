defmodule ForemanServer.Workflow.PhasePRBodyTest do
  # `PhasePR.open_pr/1` is one of the two PR-opening paths (`AutoPR.open_pr/5`
  # is the other) that appends the unresolved-review-findings block a `review`
  # phase writes into its artifact. No real git/gh: a stubbed `command_runner`
  # drives the pipeline exactly as `PhasePR.maybe_create/1` documents it.
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Workflow.PhasePR
  alias ForemanServer.Workflow.ReviewFindings

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

      "git", ["rev-parse", "--verify", _ref], _opts ->
        {"0123456789abcdef0123456789abcdef01234567", 0}

      "git", ["ls-remote", "origin", _ref], _opts ->
        {"", 0}

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

  @heading "## Review findings (the review agent's report)"

  defp block(findings) do
    json =
      Jason.encode!(%{
        "schema" => "foreman.review_findings/1",
        "reviewed" => true,
        "findings" => findings
      })

    "# Report\n\n<!-- FOREMAN_REVIEW_FINDINGS_START -->\n#{json}\n" <>
      "<!-- FOREMAN_REVIEW_FINDINGS_END -->\n"
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "severity" => "major",
        "path" => "lib/foo.ex",
        "line" => 12,
        "description" => "unchecked nil",
        "disposition" => "open",
        "source" => "repo-rules"
      },
      overrides
    )
  end

  defp phase_body(artifact) do
    assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(request(artifact))
    assert_receive {:gh_pr_create_args, args}
    body_arg(args)
  end

  defp auto_body(artifact) do
    parent = self()

    runner = fn
      "git", ["rev-list", "--count", _range], _opts ->
        {"1\n", 0}

      "git", ["rev-parse", "--verify", _ref], _opts ->
        {"0123456789abcdef0123456789abcdef01234567\n", 0}

      "git", ["ls-remote", "origin", _ref], _opts ->
        {"", 0}

      "git", ["push" | _], _opts ->
        {"", 0}

      "gh", ["pr", "list" | _], _opts ->
        {"[]", 0}

      "gh", args, _opts ->
        send(parent, {:auto_gh_args, args})
        {"https://github.com/example/repo/pull/2\n", 0}
    end

    assert {:ok, _url} =
             AutoPR.maybe_create_pr(%{
               run_id: "run-1",
               base_branch: "main",
               head_branch: "foreman/task-1/run-1",
               cwd: System.tmp_dir!(),
               artifact_path: artifact,
               command_runner: runner
             })

    assert_receive {:auto_gh_args, args}
    body_arg(args)
  end

  defp section(body) do
    [_before, rest] = String.split(body, "\n" <> @heading, parts: 2)
    @heading <> rest
  end

  test "the PR body lists the unresolved findings from a recorded block" do
    artifact =
      temp_artifact!(
        block([finding(), finding(%{"description" => "ancient-typo", "disposition" => "fixed"})])
      )

    body = phase_body(artifact)

    assert body =~ @heading
    assert body =~ "`lib/foo.ex:12`"
    assert body =~ "unchecked nil"
    refute body =~ "ancient-typo"
    assert body =~ "Fixed: 1."
  end

  test "a declined critical finding is listed as unresolved, a declined minor one is not" do
    artifact =
      temp_artifact!(
        block([
          finding(%{
            "severity" => "critical",
            "disposition" => "declined",
            "description" => "sql"
          }),
          finding(%{"severity" => "minor", "disposition" => "declined", "description" => "style"})
        ])
      )

    body = phase_body(artifact)

    assert body =~ "sql"
    assert body =~ "declined by the agent"
    refute body =~ "style"
  end

  test "AutoPR and PhasePR render the same section for every kind of block" do
    legacy =
      "<!-- FOREMAN_REVIEW_FINDINGS_START -->\n- `a.ex:1` Major — x\n<!-- FOREMAN_REVIEW_FINDINGS_END -->\n"

    for contents <- [
          block([finding()]),
          block([]),
          "# Report\n\nNo block.\n",
          block([finding()]) <> block([finding()]),
          legacy
        ] do
      artifact = temp_artifact!(contents)
      assert section(phase_body(artifact)) == section(auto_body(artifact))
    end
  end

  test "an agent-written description is inert in the body on both paths" do
    hostile =
      "ping @someone and @org/team, Fixes #1, Closes #2, [x](http://e.example), " <>
        "![](http://e.example/p.png), <img src=x>, <!-- hide, ```` ``` ````\n" <>
        "<!-- FOREMAN_REVIEW_FINDINGS_START -->\n## injected"

    artifact = temp_artifact!(block([finding(%{"description" => hostile})]))

    for body <- [phase_body(artifact), auto_body(artifact)] do
      # Outside code spans the section holds none of the hostile constructs.
      outside = String.replace(body, ~r/`[^`\n]*`/, "")

      for fragment <-
            [
              "@someone",
              "@org/team",
              "Fixes #1",
              "Closes #2",
              "](http",
              "<img",
              "<!--",
              "## injected"
            ] do
        refute outside =~ fragment, "#{inspect(fragment)} is live in the body"
      end

      # The description is still there, inside its span, on a bullet line.
      assert body =~ ~r/^- \*\*major\*\* `lib\/foo\.ex:12` — `.*Fixes #1.*`$/m
      # No line starts with a marker, and the counts line still closes the body.
      refute body =~ ~r/^<!--/m
      assert body =~ ~r/Fixed: 0\. Declined: 0 \(.*\)\.\n\z/
      assert ReviewFindings.parse(body) == :absent
    end
  end

  test "an absent block says the review evidence is missing, not that nothing was found" do
    body = phase_body(temp_artifact!("# Report\n\nNothing to report.\n"))

    assert body =~ @heading
    assert body =~ "review evidence is missing"
    assert body =~ "not a clean review"
    refute body =~ "nothing unresolved"
  end

  test "a nil artifact path is missing evidence too" do
    body = phase_body(nil)

    assert body =~ "review evidence is missing"
  end

  test "multiple_blocks and legacy_format name the defect and are not a clean review" do
    multiple = phase_body(temp_artifact!(block([]) <> block([])))
    assert multiple =~ "`multiple_blocks`"
    assert multiple =~ "not a clean review"
    refute multiple =~ "nothing unresolved"

    legacy =
      phase_body(
        temp_artifact!(
          "<!-- FOREMAN_REVIEW_FINDINGS_START -->\n- `a.ex:1` Major — x\n<!-- FOREMAN_REVIEW_FINDINGS_END -->\n"
        )
      )

    assert legacy =~ "`legacy_format`"
    refute legacy =~ "nothing unresolved"
  end

  test "an unreadable artifact is named, not rendered as an empty section" do
    body =
      phase_body(
        Path.join(System.tmp_dir!(), "phase-pr-missing-#{System.unique_integer([:positive])}.md")
      )

    assert body =~ "`unreadable`"
    assert body =~ "not a clean review"
  end
end
