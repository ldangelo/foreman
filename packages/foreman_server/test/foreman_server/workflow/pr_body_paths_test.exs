defmodule ForemanServer.Workflow.PrBodyPathsTest do
  @moduledoc """
  A PR body is public; the worktree it was written in is not.

  Both PR body builders interpolated the artifact path verbatim, so the body
  carried `/Users/<operator>/.foreman/worktrees/<project>/<run>/workspace/...`
  and a review finding could carry the same absolute prefix. Once the worktree
  is cleaned up the path resolves to nothing anyway, so the leak bought nothing.

  These tests drive the real `PhasePR` / `AutoPR` creation paths with a stubbed
  command runner and assert on the `--body` argument that would reach GitHub.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Workflow.PhasePR
  alias ForemanServer.Workflow.PrBodyPath

  setup do
    # A real directory whose absolute path contains `/Users/` and
    # `.foreman/worktrees/`, so the leak assertions fail on the old behaviour
    # instead of passing vacuously.
    root = Path.join(System.tmp_dir!(), "pr-body-path-test-#{System.unique_integer([:positive])}")

    worktree =
      Path.join([
        root,
        "Users",
        "tester",
        ".foreman",
        "worktrees",
        "foreman",
        "run-1",
        "workspace"
      ])

    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(root) end)

    artifact =
      Path.join([worktree, "docs", "reports", "foreman-beads:foreman:task-1", "FIX_REPORT.md"])

    {:ok, worktree: worktree, artifact: artifact, root: root}
  end

  describe "repo_relative/2" do
    test "returns an already-relative path unchanged", %{worktree: worktree} do
      assert {:ok, "docs/reports/foreman/FIX_REPORT.md"} =
               PrBodyPath.repo_relative("docs/reports/foreman/FIX_REPORT.md", worktree)
    end

    test "returns a relative path unchanged even when the root is unknown" do
      assert {:ok, "lib/foo.ex"} = PrBodyPath.repo_relative("lib/foo.ex", nil)
    end

    test "rewrites an absolute path inside the root relative to it", %{
      worktree: worktree,
      artifact: artifact
    } do
      assert {:ok, "docs/reports/foreman-beads:foreman:task-1/FIX_REPORT.md"} =
               PrBodyPath.repo_relative(artifact, worktree)
    end

    test "refuses an absolute path outside the root", %{worktree: worktree} do
      assert :outside_repo = PrBodyPath.repo_relative("/etc/passwd", worktree)
    end

    test "refuses an absolute path when the root is unknown", %{artifact: artifact} do
      assert :outside_repo = PrBodyPath.repo_relative(artifact, nil)
    end

    test "treats no path as outside the repo", %{worktree: worktree} do
      assert :outside_repo = PrBodyPath.repo_relative(nil, worktree)
    end

    test "trims surrounding whitespace before classifying the path", %{worktree: worktree} do
      assert {:ok, "lib/foo.ex"} = PrBodyPath.repo_relative("  lib/foo.ex  ", worktree)

      assert :outside_repo =
               PrBodyPath.repo_relative(" /Users/alice/work/lib/foo.ex ", worktree)
    end

    test "raises on a path that is neither a string nor nil", %{worktree: worktree} do
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative(%{}, worktree) end
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative(:worktree, worktree) end
    end

    test "raises on a blank path", %{worktree: worktree} do
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative("   ", worktree) end
    end

    test "raises on a root that is blank or not a string", %{artifact: artifact} do
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative(artifact, "") end
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative(artifact, "   ") end
      assert_raise ArgumentError, fn -> PrBodyPath.repo_relative(artifact, 123) end
    end
  end

  describe "artifact_line/2" do
    test "emits the repo-relative path", %{worktree: worktree, artifact: artifact} do
      assert PrBodyPath.artifact_line(artifact, worktree) ==
               "\nArtifact: docs/reports/foreman-beads:foreman:task-1/FIX_REPORT.md\n"
    end

    test "omits the line when there is no artifact", %{worktree: worktree} do
      assert PrBodyPath.artifact_line(nil, worktree) == ""
    end

    test "omits the line when no relative form can be computed", %{
      worktree: worktree,
      artifact: artifact
    } do
      assert PrBodyPath.artifact_line("/tmp/elsewhere/REPORT.md", worktree) == ""
      assert PrBodyPath.artifact_line(artifact, nil) == ""
    end

    test "raises on a path that is neither a string nor nil", %{worktree: worktree} do
      assert_raise ArgumentError, fn -> PrBodyPath.artifact_line(:artifact, worktree) end
    end

    test "raises on a root that is blank or not a string", %{artifact: artifact} do
      assert_raise ArgumentError, fn -> PrBodyPath.artifact_line(artifact, "") end
      assert_raise ArgumentError, fn -> PrBodyPath.artifact_line(artifact, 123) end
    end
  end

  describe "display_path/1" do
    test "keeps a repo-relative path as written" do
      assert PrBodyPath.display_path("lib/foo.ex") == "lib/foo.ex"
    end

    test "reduces an absolute path to its basename", %{artifact: artifact} do
      assert PrBodyPath.display_path(artifact) == "…/FIX_REPORT.md"
    end

    test "trims surrounding whitespace before classifying the path" do
      assert PrBodyPath.display_path("  lib/foo.ex  ") == "lib/foo.ex"
      assert PrBodyPath.display_path(" /Users/alice/work/lib/foo.ex ") == "…/foo.ex"
    end

    test "raises on a path that is not a string" do
      assert_raise ArgumentError, fn -> PrBodyPath.display_path(nil) end
    end
  end

  describe "PhasePR body" do
    test "carries the artifact relative to the worktree and no host path", ctx do
      body = phase_body(ctx, [%{"path" => "lib/foo.ex", "line" => 12}])

      assert body =~ "Artifact: docs/reports/foreman-beads:foreman:task-1/FIX_REPORT.md"
      assert body =~ "`lib/foo.ex:12`"
      refute_leaks(body)
    end

    test "omits the artifact line when the artifact sits outside the worktree", ctx do
      outside = Path.join([ctx.root, "outside", "REPORT.md"])
      body = phase_body(ctx, [], outside)

      refute body =~ "Artifact:"
      refute body =~ "outside"
      refute_leaks(body)
    end

    test "reduces an absolute finding path to its basename", ctx do
      body =
        phase_body(ctx, [
          %{
            "path" => Path.join([ctx.worktree, "lib", "private.ex"]),
            "line" => 7
          }
        ])

      assert body =~ "…/private.ex:7"
      refute_leaks(body)
    end
  end

  describe "AutoPR body" do
    test "carries the artifact relative to the run worktree and no host path", ctx do
      body = auto_body(ctx, ctx.artifact, ctx.worktree)

      assert body =~ "Artifact: docs/reports/foreman-beads:foreman:task-1/FIX_REPORT.md"
      refute_leaks(body)
    end

    test "omits the artifact line when the artifact sits outside the root", ctx do
      outside = Path.join([ctx.root, "outside", "REPORT.md"])
      body = auto_body(ctx, outside, ctx.worktree)

      refute body =~ "Artifact:"
      refute_leaks(body)
    end
  end

  defp phase_body(ctx, findings, artifact_path \\ nil) do
    artifact_path = artifact_path || ctx.artifact
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, block(findings))
    parent = self()

    # The `pr_create` effect key is global per (run_id, head_branch,
    # base_branch), so every test needs its own identifiers or the second one
    # is refused as `:effect_undecided`.
    uniq = System.unique_integer([:positive])
    run_id = "run-pr-body-#{uniq}"
    head_branch = "foreman/pr-body-#{uniq}/run-#{uniq}"

    runner = fn
      "git", ["rev-list", "--count", _range], _opts ->
        {"1", 0}

      "git", ["rev-parse", "--verify", _ref], _opts ->
        {"0123456789abcdef0123456789abcdef01234567", 0}

      "git", ["ls-remote", "origin", _ref], _opts ->
        {"", 0}

      "git", ["push", "-u", "origin", _branch], _opts ->
        {"", 0}

      # The title lookup reads the run's commit subjects; none is conventional here.
      "git", ["log" | _rest], _opts ->
        {"", 0}

      "gh", ["pr", "list" | _rest], _opts ->
        {"[]", 0}

      "gh", ["pr", "create" | _rest] = args, _opts ->
        send(parent, {:phase_pr_create_args, args})
        {"https://github.com/example/repo/pull/1", 0}
    end

    request = %PhasePR.Request{
      run_id: run_id,
      phase_id: "phase-pr-body-#{uniq}",
      phase_index: 1,
      phase_name: "coderabbit-review",
      base_branch: "main",
      head_branch: head_branch,
      cwd: ctx.worktree,
      artifact_path: artifact_path,
      command_runner: runner
    }

    assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(request)
    assert_receive {:phase_pr_create_args, args}
    body_arg(args)
  end

  defp auto_body(ctx, artifact_path, artifact_root) do
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, block([]))
    parent = self()

    uniq = System.unique_integer([:positive])
    run_id = "run-pr-body-#{uniq}"
    head_branch = "foreman/pr-body-#{uniq}/run-#{uniq}"

    runner = fn
      "git", ["rev-list", "--count", _range], _opts ->
        {"1\n", 0}

      "git", ["rev-parse", "--verify", _ref], _opts ->
        {"0123456789abcdef0123456789abcdef01234567\n", 0}

      "git", ["ls-remote", "origin", _ref], _opts ->
        {"", 0}

      "git", ["push" | _rest], _opts ->
        {"", 0}

      "gh", ["pr", "list" | _rest], _opts ->
        {"[]\n", 0}

      "gh", args, _opts ->
        send(parent, {:auto_gh_args, args})
        {"https://github.com/example/repo/pull/2\n", 0}
    end

    assert {:ok, "https://github.com/example/repo/pull/2"} =
             AutoPR.maybe_create_pr(%{
               run_id: run_id,
               base_branch: "main",
               head_branch: head_branch,
               cwd: ctx.worktree,
               artifact_root: artifact_root,
               artifact_path: artifact_path,
               command_runner: runner
             })

    assert_receive {:auto_gh_args, args}
    body_arg(args)
  end

  # `gh_pr_create/2` passes the body as the argv element after `--body`.
  defp body_arg(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--body", body] -> body
      _ -> nil
    end)
  end

  defp refute_leaks(body) do
    refute body =~ "/Users/"
    refute body =~ "/home/"
    refute body =~ ".foreman/worktrees/"
    refute body =~ System.tmp_dir!()
  end

  defp block(findings) do
    json =
      Jason.encode!(%{
        "schema" => "foreman.review_findings/1",
        "reviewed" => true,
        "findings" => Enum.map(findings, &finding/1)
      })

    "# Report\n\n<!-- FOREMAN_REVIEW_FINDINGS_START -->\n#{json}\n<!-- FOREMAN_REVIEW_FINDINGS_END -->\n"
  end

  defp finding(overrides) do
    Map.merge(
      %{
        "severity" => "minor",
        "path" => "lib/foo.ex",
        "line" => 12,
        "description" => "stale assert",
        "disposition" => "open",
        "source" => "coderabbit"
      },
      overrides
    )
  end
end
