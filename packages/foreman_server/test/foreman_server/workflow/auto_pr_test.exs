defmodule ForemanServer.Workflow.AutoPRTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.AutoPR

  setup do
    repo = Path.join(System.tmp_dir!(), "autopr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "--initial-branch=main"])
    {_, 0} = git.(["config", "user.email", "test@example.com"])
    {_, 0} = git.(["config", "user.name", "Test"])
    File.write!(Path.join(repo, "base.txt"), "base\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base"])

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo, git: git}
  end

  defp commit_on_branch(%{repo: repo, git: git}, branch) do
    {_, 0} = git.(["checkout", "-b", branch])
    File.write!(Path.join(repo, "#{String.replace(branch, "/", "-")}.txt"), "work\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "work on #{branch}"])
    {_, 0} = git.(["checkout", "main"])
    :ok
  end

  defp prepend_path(path, fun) do
    old_path = System.get_env("PATH")
    System.put_env("PATH", path <> Path.delimiter() <> old_path)

    try do
      fun.()
    after
      System.put_env("PATH", old_path)
    end
  end

  defp write_executable(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp command_shim_dir(capture_file, opts \\ []) do
    bin = Path.join(System.tmp_dir!(), "autopr-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)

    rev_count = Keyword.get(opts, :rev_count, "1")
    push_exit = Keyword.get(opts, :push_exit, 0)
    gh_exit = Keyword.get(opts, :gh_exit, 0)

    write_executable(
      Path.join(bin, "git"),
      """
      #!/usr/bin/env sh
      printf 'git %s\n' "$*" >> #{capture_file}
      if [ "$1" = "rev-list" ]; then
        echo #{rev_count}
        exit 0
      fi
      if [ "$1" = "push" ]; then
        exit #{push_exit}
      fi
      exit 0
      """
    )

    write_executable(
      Path.join(bin, "gh"),
      """
      #!/usr/bin/env sh
      printf 'gh' >> #{capture_file}
      for arg in "$@"; do
        printf '\t%s' "$arg" >> #{capture_file}
      done
      printf '\n' >> #{capture_file}
      if [ #{gh_exit} -eq 0 ]; then
        echo https://github.com/acme/repo/pull/1
      else
        echo gh failed
      fi
      exit #{gh_exit}
      """
    )

    bin
  end

  describe "head branch resolution" do
    test "uses the Foreman-derived branch from run state" do
      ctx = %{
        run_id: "run-1",
        base_branch: "main",
        head_branch: "foreman/run-1/implement",
        cwd: "/nonexistent-so-git-fails"
      }

      assert {:error, {:rev_list_failed, _, _}} = AutoPR.maybe_create_pr(ctx)
    end

    test "errors when neither run state nor artifact supplies a branch" do
      ctx = %{run_id: "run-1", base_branch: "main", head_branch: nil, cwd: nil}
      assert {:error, :no_head_branch} = AutoPR.maybe_create_pr(ctx)
    end

    test "an artifact FOREMAN_BRANCH marker overrides run state" do
      assert AutoPR.branch_override("noise\nFOREMAN_BRANCH=skill/own-branch\nmore") ==
               "skill/own-branch"
    end

    test "branch_override/1 is nil when the artifact declares no branch" do
      refute AutoPR.branch_override("FOREMAN_COMPLETE=true\nno branch here")
    end
  end

  describe "PR decision is driven by commits, not a marker" do
    test "noop when the head branch has no commits beyond base", %{repo: repo, git: git} do
      {_, 0} = git.(["branch", "foreman/run-2/implement"])

      ctx = %{
        run_id: "run-2",
        base_branch: "main",
        head_branch: "foreman/run-2/implement",
        cwd: repo
      }

      assert AutoPR.maybe_create_pr(ctx) == :noop
    end

    test "attempts a PR when the head branch has commits, with no marker present", ctx do
      commit_on_branch(ctx, "foreman/run-3/implement")

      context = %{
        run_id: "run-3",
        base_branch: "main",
        head_branch: "foreman/run-3/implement",
        cwd: ctx.repo
      }

      assert {:error, reason} = AutoPR.maybe_create_pr(context)
      assert elem(reason, 0) in [:git_push_failed, :gh_pr_create_failed]
    end

    test "a missing artifact does not prevent a PR", ctx do
      commit_on_branch(ctx, "foreman/run-4/implement")

      context = %{
        run_id: "run-4",
        base_branch: "main",
        head_branch: "foreman/run-4/implement",
        artifact_path: "/definitely/not/a/real/path",
        cwd: ctx.repo
      }

      refute AutoPR.maybe_create_pr(context) == :noop
    end

    test "a git failure is an error, never a silent noop" do
      ctx = %{
        run_id: "run-5",
        base_branch: "main",
        head_branch: "does/not/exist",
        cwd: System.tmp_dir!()
      }

      assert {:error, _} = AutoPR.maybe_create_pr(ctx)
    end
  end

  describe "context validation" do
    test "rejects a context missing required keys" do
      assert {:error, {:invalid_context, _}} = AutoPR.maybe_create_pr(%{run_id: "run-6"})
      assert {:error, {:invalid_context, _}} = AutoPR.maybe_create_pr(%{base_branch: "main"})
    end

    test "rejects a blank base branch" do
      assert {:error, {:invalid_context, _}} =
               AutoPR.maybe_create_pr(%{run_id: "run-7", base_branch: ""})
    end

    test "validates full task metadata, fallback absence, and ignored unknown keys" do
      assert {:ok, %{title: "Task title", description: "Task body", task_id: "task-1"}} =
               AutoPR.validate_task_summary(%{
                 task_title: "Task title",
                 task_description: "Task body",
                 task_id: "task-1",
                 task_unknown: "ignored"
               })

      assert AutoPR.validate_task_summary(%{other: "value"}) == {:ok, nil}
    end

    test "rejects partial, blank, and non-string task metadata before git commands" do
      for context <- [
            %{task_title: "Title"},
            %{task_description: "Body"},
            %{task_title: " ", task_description: "Body"},
            %{task_title: "Title", task_description: ""},
            %{task_title: 1, task_description: "Body"},
            %{task_title: "Title", task_description: %{}}
          ] do
        assert {:error, {:invalid_task_summary, _}} =
                 AutoPR.maybe_create_pr(
                   Map.merge(context, %{
                     run_id: "run-invalid",
                     base_branch: "main",
                     head_branch: "head",
                     cwd: "/path-that-would-fail-if-git-ran"
                   })
                 )
      end
    end
  end

  describe "PR text composition" do
    test "preserves exact legacy fallback title and body with no artifact" do
      assert AutoPR.compose_pr_text("run-legacy", nil, nil) ==
               {"feat(run): run-legacy", "Foreman run `run-legacy` complete.\n"}
    end

    test "preserves fallback artifact and findings ordering" do
      artifact =
        Path.join(System.tmp_dir!(), "autopr-artifact-#{System.unique_integer([:positive])}.md")

      try do
        File.write!(artifact, """
        done
        <!-- FOREMAN_REVIEW_FINDINGS_START -->
        - fix this
        <!-- FOREMAN_REVIEW_FINDINGS_END -->
        """)

        {_title, body} = AutoPR.compose_pr_text("run-findings", artifact, nil)

        assert body =~ "Foreman run `run-findings` complete.\n\nArtifact: #{artifact}\n"
        assert body =~ "## Unresolved review findings\n\n- fix this\n"
      after
        File.rm(artifact)
      end
    end

    test "adds task summary before artifact and findings while preserving markdown and ids" do
      artifact =
        Path.join(
          System.tmp_dir!(),
          "autopr-task-artifact-#{System.unique_integer([:positive])}.md"
        )

      try do
        File.write!(artifact, """
        done
        <!-- FOREMAN_REVIEW_FINDINGS_START -->
        - unresolved
        <!-- FOREMAN_REVIEW_FINDINGS_END -->
        """)

        summary = %{
          title: "Fix AutoPR / title \"safe\"",
          description: "Line 1\n\n- markdown stays",
          task_id: "task-123",
          external_id: "bead-7",
          external_link: "https://beads.example/bead-7"
        }

        {title, body} = AutoPR.compose_pr_text("run-task", artifact, summary)

        assert title == "Fix AutoPR / title \"safe\""
        assert body =~ "## Task summary"
        assert body =~ "### Fix AutoPR / title \"safe\""
        assert body =~ "Line 1\n\n- markdown stays"
        assert body =~ "- Task ID: task-123"
        assert body =~ "- External ID: bead-7"
        assert body =~ "- External Link: https://beads.example/bead-7"
        assert body =~ "Artifact: #{artifact}"
        assert body =~ "## Unresolved review findings\n\n- unresolved\n"
        assert String.index(body, "## Task summary") < String.index(body, "Artifact:")

        assert String.index(body, "Artifact:") <
                 String.index(body, "## Unresolved review findings")
      after
        File.rm(artifact)
      end
    end

    test "omits task id placeholders when ids are absent" do
      {_title, body} =
        AutoPR.compose_pr_text("run-no-ids", nil, %{
          title: "Title",
          description: "Body"
        })

      refute body =~ "Task ID:"
      refute body =~ "External ID:"
      refute body =~ "External Link:"
    end
  end

  describe "command boundary and logging" do
    test "passes task title as a gh argv value and preserves push ordering" do
      capture =
        Path.join(System.tmp_dir!(), "autopr-capture-#{System.unique_integer([:positive])}.log")

      bin = command_shim_dir(capture)

      try do
        result =
          prepend_path(bin, fn ->
            AutoPR.maybe_create_pr(%{
              run_id: "run-cmd",
              base_branch: "main",
              head_branch: "foreman/run-cmd/final",
              cwd: System.tmp_dir!(),
              task_title: "Fix AutoPR / title \"safe\" $(no-shell)",
              task_description: "body"
            })
          end)

        assert result == {:ok, "https://github.com/acme/repo/pull/1"}

        lines = capture |> File.read!() |> String.split("\n", trim: true)
        assert Enum.at(lines, 0) =~ "git rev-list --count main..foreman/run-cmd/final"
        assert Enum.at(lines, 1) =~ "git push -u origin foreman/run-cmd/final"

        gh_line = Enum.find(lines, &String.starts_with?(&1, "gh\t"))
        assert gh_line =~ "\t--title\tFix AutoPR / title \"safe\" $(no-shell)\t"
        assert gh_line =~ "\t--body\tForeman run `run-cmd` complete."
      after
        File.rm(capture)
        File.rm_rf(bin)
      end
    end

    test "does not log task descriptions or full PR body" do
      capture =
        Path.join(System.tmp_dir!(), "autopr-capture-#{System.unique_integer([:positive])}.log")

      bin = command_shim_dir(capture, gh_exit: 1)
      secret = "sentinel-secret-description"

      try do
        log =
          capture_log(fn ->
            prepend_path(bin, fn ->
              assert {:error, {:gh_pr_create_failed, 1, "gh failed"}} =
                       AutoPR.maybe_create_pr(%{
                         run_id: "run-log",
                         base_branch: "main",
                         head_branch: "foreman/run-log/final",
                         cwd: System.tmp_dir!(),
                         task_title: "Task title",
                         task_description: secret
                       })
            end)
          end)

        assert log =~ "run-log"
        refute log =~ secret
        refute log =~ "## Task summary"
      after
        File.rm(capture)
        File.rm_rf(bin)
      end
    end
  end

  describe "the base branch decides what the PR would contain" do
    test "a head level with its feature-branch base is a noop, though ahead of main", ctx do
      %{repo: repo, git: git} = ctx
      {_, 0} = git.(["checkout", "-b", "feat/mcp-run-details"])
      File.write!(Path.join(repo, "unrelated.txt"), "another session's commit\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "unrelated session work"])
      {_, 0} = git.(["branch", "foreman/run-8/create-prd"])

      assert AutoPR.maybe_create_pr(%{
               run_id: "run-8",
               base_branch: "feat/mcp-run-details",
               head_branch: "foreman/run-8/create-prd",
               cwd: repo
             }) == :noop

      assert {:error, reason} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-8",
                 base_branch: "main",
                 head_branch: "foreman/run-8/create-prd",
                 cwd: repo
               })

      assert elem(reason, 0) in [:git_push_failed, :gh_pr_create_failed]
    end

    test "a head with a commit beyond its feature-branch base proceeds", ctx do
      %{repo: repo, git: git} = ctx
      {_, 0} = git.(["checkout", "-b", "feat/mcp-run-details"])
      File.write!(Path.join(repo, "unrelated.txt"), "another session's commit\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "unrelated session work"])
      {_, 0} = git.(["checkout", "-b", "foreman/run-9/create-prd"])
      File.write!(Path.join(repo, "prd.md"), "the run's document\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "PRD"])

      assert {:error, reason} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-9",
                 base_branch: "feat/mcp-run-details",
                 head_branch: "foreman/run-9/create-prd",
                 cwd: repo
               })

      assert elem(reason, 0) in [:git_push_failed, :gh_pr_create_failed]
    end
  end
end
