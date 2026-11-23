defmodule ForemanServer.Workflow.PrBodyPathsTest do
  @moduledoc """
  Asserts the PR bodies Foreman creates never carry a host-local absolute path.

  Two surfaces emit a path into a GitHub-visible body: the `Artifact:` line that
  `PhasePR` and `AutoPR` render from an artifact path, and the `path:line`
  prefix that `ReviewFindings` renders from a finding that reported one. The
  finding fixture is deliberately a different shape in each test (the GitHub API
  error string `ReviewFindings` parses versus the `foreman_code_quality_review`
  artifact AutoPR reads) because the scrubbing sits in `finding_line/1`, which
  both must pass through.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Workflow.PhasePR
  alias ForemanServer.Workflow.PrBodyPath

  test "PhasePR names the artifact relative to the repo, not by absolute path" do
    %{cwd: cwd, artifact: artifact} = tmp_repo()

    body =
      %PhasePR.Request{
        run_id: "run-1",
        task_id: "task-1",
        phase_tag: "implement",
        project_id: "p1",
        worktree_id: "wt1",
        worktree_path: cwd,
        head_sha: "abc123",
        branch: "foreman/t-1/run-1",
        base_ref: "main",
        title: "t",
        body: "",
        provider: :github,
        cwd: cwd,
        timeout_ms: 5_000,
        artifact_path: artifact
      }
      |> PhasePR.maybe_create()
      |> body_arg(stub_runner())

    assert body =~ "Artifact: docs/reports/x/FIX_REPORT.md"
    refute body =~ cwd
    refute body =~ "/Users/"
    refute body =~ "/home/"
  end

  test "AutoPR names the artifact relative to the repo, not by absolute path" do
    %{cwd: cwd, artifact: artifact} = tmp_repo()
    runner = stub_runner()

    {:ok, %{number: 7}} =
      AutoPR.maybe_create_pr(%{
        run_id: "run-1",
        base_branch: "main",
        head_branch: "foreman/t/run-1",
        cwd: cwd,
        artifact_path: artifact,
        command_runner: runner
      })

    body = recv_gh_create_args(runner)

    assert body =~ "Artifact: docs/reports/x/FIX_REPORT.md"
    refute body =~ cwd
    refute body =~ "/Users/"
    refute body =~ "/home/"
  end

  test "the Artifact line is omitted when the path is outside the repo" do
    %{cwd: cwd} = tmp_repo()
    outside = Path.join(File.mkdir!(Path.join(System.tmp_dir!(), "pr-body-outside-#{System.unique_integer([:positive])})), "FIX_REPORT.md")

    body =
      %PhasePR.Request{
        run_id: "run-1",
        task_id: "task-1",
        phase_tag: "implement",
        project_id: "p1",
        worktree_id: "wt1",
        worktree_path: cwd,
        head_sha: "abc123",
        branch: "foreman/t-1/run-1",
        base_ref: "main",
        title: "t",
        body: "",
        provider: :github,
        cwd: cwd,
        timeout_ms: 5_000,
        artifact_path: outside
      }
      |> PhasePR.maybe_create()
      |> body_arg(stub_runner())

    refute body =~ "Artifact:"
    refute body =~ "/Users/"
    refute body =~ "/home/"
  end

  test "a finding that reported an absolute path shows only its basename" do
    %{cwd: cwd, artifact: artifact} = tmp_repo()
    File.write!(artifact, block([finding(%{"path" => "/Users/someone/wt/lib/foo.ex"})]))
    runner = stub_runner()

    phase_body =
      %PhasePR.Request{
        run_id: "run-1",
        task_id: "task-1",
        phase_tag: "implement",
        project_id: "p1",
        worktree_id: "wt1",
        worktree_path: cwd,
        head_sha: "abc123",
        branch: "foreman/t-1/run-1",
        base_ref: "main",
        title: "t",
        body: "",
        provider: :github,
        cwd: cwd,
        timeout_ms: 5_000,
        artifact_path: artifact
      }
      |> PhasePR.maybe_create()
      |> body_arg(runner)

    {:ok, %{number: 8}} =
      AutoPR.maybe_create_pr(%{
        run_id: "run-2",
        base_branch: "main",
        head_branch: "foreman/t/run-2",
        cwd: cwd,
        artifact_path: artifact,
        command_runner: runner
      })

    auto_body = recv_gh_create_args(runner)

    for body <- [phase_body, auto_body] do
      assert body =~ "…/foo.ex:12"
      refute body =~ "/Users/"
      refute body =~ "/home/"
    end
  end

  describe "PrBodyPath" do
    test "repo_relative/2 keeps a relative path and rebases one inside the root" do
      root = Path.join(System.tmp_dir!(), "pr-body-path-root")

      assert PrBodyPath.repo_relative("docs/reports/x/FIX_REPORT.md", root) ==
               {:ok, "docs/reports/x/FIX_REPORT.md"}

      assert PrBodyPath.repo_relative(Path.join(root, "docs/reports/x/FIX_REPORT.md"), root) ==
               {:ok, "docs/reports/x/FIX_REPORT.md"}
    end

    test "repo_relative/2 returns :outside_repo for an outside path or a missing root" do
      assert PrBodyPath.repo_relative("/tmp/elsewhere/FIX_REPORT.md", "/tmp/root") == :outside_repo
      assert PrBodyPath.repo_relative("/tmp/root/x.md", nil) == :outside_repo
      assert PrBodyPath.artifact_line("/tmp/elsewhere/FIX_REPORT.md", "/tmp/root") == ""
    end

    test "display_path/1 strips the host prefix of an absolute path" do
      assert PrBodyPath.display_path("/Users/someone/wt/lib/foo.ex") == "…/foo.ex"
      assert PrBodyPath.display_path("lib/foo.ex") == "lib/foo.ex"
    end
  end

  defp tmp_repo do
    cwd = Path.join(System.tmp_dir!(), "pr-body-paths-#{System.unique_integer([:positive])}")
    reports = Path.join(cwd, "docs/reports/x")
    File.mkdir_p!(reports)
    artifact = Path.join(reports, "FIX_REPORT.md")
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd, artifact: artifact}
  end

  defp recv_gh_create_args(runner) do
    assert_receive {:gh_pr_create_args, args}, 1_000
    body_arg_from_args(args)
  end

  defp body_arg({:ok, %{stdout: stdout}}, _runner) do
    [%{url: url}] = Jason.decode!(stdout)
    assert_receive {:gh_pr_create_args, args}, 1_000
    _ = url
    body_arg_from_args(args)
  end

  # Stub the read-only git and gh calls PhasePR/AutoPR make before creating a PR,
  # and capture the `gh pr create --body` argument so each test can assert on the
  # body that would actually have been posted.
  defp stub_runner do
    test_pid = self()

    fn cmd, args, _opts ->
      case {cmd, args} do
        {_, ["rev-list", "--count", "main..HEAD"]} ->
          {:ok, %{exit_code: 0, stdout: "3\n", stderr: ""}}

        {_, ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {:ok, %{exit_code: 0, stdout: "foreman/t-1/run-1\n", stderr: ""}}

        {_, ["push", "origin", "abc123:refs/heads/foreman/t-1/run-1"]} ->
          {:ok, %{exit_code: 0, stdout: "", stderr: ""}}

        {"gh", ["pr", "list", "--head", "foreman/t-1/run-1", "--state", "open", "--json", "number"]} ->
          {:ok, %{exit_code: 0, stdout: "[]", stderr: ""}}

        {"gh", args} ->
          send(test_pid, {:gh_pr_create_args, args})
          {:ok, %{exit_code: 0, stdout: ~S([{"number":7,"url":"http://x/7"}]), stderr: ""}}

        _ ->
          {:error, :unexpected}
      end
    end
  end

  defp body_arg_from_args(args) do
    Enum.find_value(args, fn
      "--body=" <> body -> body
      _ -> nil
    end)
  end

  # The findings block `ReviewFindings.pr_section/2` reads, carrying one finding
  # that reported an absolute path.
  defp block(findings) do
    body =
      findings
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    %{
      type: "json",
      attrs: %{
        "tool" => "github_code_quality_review",
        "outcome" => "partial",
        "reconcile_status" => "ok",
        "result" => %{"body" => body, "reconcile_warnings" => []}
      }
    }
  end

  # The shape `ReviewFindings.parse_finding/1` accepts: an API error object with
  # the `path:line` prefix in its message.
  defp finding(attrs) do
    Map.merge(
      %{
        "code" => 422,
        "message" => ~S(Invalid request.\n\n"labels" failed validation),
        "documentation_url" => "https://docs.github.com/rest/pulls/pulls#update-a-pull-request"
      },
      attrs
    )
  end
end
