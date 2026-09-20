defmodule ForemanServer.Workflow.AutoPRTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.AutoPR

  # AutoPR previously had no test coverage at all, which is why nobody noticed
  # that it required a `FOREMAN_COMPLETE` marker no skill ever emitted — so a
  # PR could not land from any workflow, and the failure was invisible because
  # `:noop` was logged at info while the run completed successfully.
  #
  # These tests exercise the real decision logic against a real git repo. The
  # `gh` invocation itself is not exercised (it would hit the network); the
  # boundary tested here is "does AutoPR decide to open a PR, and from which
  # branch".

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
    File.write!(Path.join(repo, "#{branch |> String.replace("/", "-")}.txt"), "work\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "work on #{branch}"])
    {_, 0} = git.(["checkout", "main"])
    :ok
  end

  describe "head branch resolution" do
    test "uses the Foreman-derived branch from run state" do
      # The whole point of the rewrite: no artifact, no marker, still resolves.
      ctx = %{
        run_id: "run-1",
        base_branch: "main",
        head_branch: "foreman/run-1/implement",
        cwd: "/nonexistent-so-git-fails"
      }

      # Reaches the git probe, meaning the branch resolved.
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

      # Commits exist, so AutoPR publishes the branch and then runs
      # `gh pr create`. This temp repo has no remote, so the push fails first.
      # The contract under test is that it got past the decision and surfaced
      # an error rather than silently no-opping, which is what used to happen.
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
  end

  describe "task metadata title/body" do
    test "uses task title and description exactly as gh pr create arguments" do
      parent = self()

      runner = fn
        "git", ["rev-list", "--count", "main..foreman/run-10/implement"], _opts ->
          {"1\n", 0}

        "git", ["push", "-u", "origin", "foreman/run-10/implement"], _opts ->
          {"", 0}

        "gh", args, _opts ->
          send(parent, {:gh_args, args})
          {"https://github.com/acme/repo/pull/10\n", 0}
      end

      title = "AutoPR PR title/description: actual implementation / #42"
      body = "Implement the thing.\n\n- preserve markdown\n- keep $shell as text"

      assert {:ok, "https://github.com/acme/repo/pull/10"} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-10",
                 base_branch: "main",
                 head_branch: "foreman/run-10/implement",
                 task_title: title,
                 task_description: body,
                 command_runner: runner
               })

      assert_receive {:gh_args, args}
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--title")) + 1) == title
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1) == body
    end

    test "a run with only a task title falls back to the generated body" do
      parent = self()

      runner = fn
        "git", ["rev-list", "--count", "main..foreman/run-title-only/implement"], _opts ->
          {"1\n", 0}

        "git", ["push", "-u", "origin", "foreman/run-title-only/implement"], _opts ->
          {"", 0}

        "gh", args, _opts ->
          send(parent, {:gh_args, args})
          {"https://github.com/acme/repo/pull/13\n", 0}
      end

      # An unset description is absent from the context (RunExecutor omits nil
      # fields) — that must fall back, not hard-fail and silently produce no PR.
      assert {:ok, _url} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-title-only",
                 base_branch: "main",
                 head_branch: "foreman/run-title-only/implement",
                 task_title: "Only a title",
                 command_runner: runner
               })

      assert_receive {:gh_args, args}
      title = Enum.at(args, Enum.find_index(args, &(&1 == "--title")) + 1)
      body = Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)
      assert title == "Only a title"
      assert body =~ "Foreman run `run-title-only` complete."
    end

    test "an explicitly nil task field is malformed, not absent" do
      runner = fn
        "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
        executable, args, _opts -> flunk("unexpected command: #{executable} #{inspect(args)}")
      end

      assert {:error, %AutoPR.TaskMetadataError{field: :description, reason: :invalid}} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-nil-description",
                 base_branch: "main",
                 head_branch: "foreman/run-nil-description/implement",
                 task_title: "Task title",
                 task_description: nil,
                 command_runner: runner
               })

      assert {:error, %AutoPR.TaskMetadataError{field: :title, reason: :invalid}} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-nil-title",
                 base_branch: "main",
                 head_branch: "foreman/run-nil-title/implement",
                 task_title: nil,
                 command_runner: runner
               })
    end

    test "validates task metadata before publishing the head branch" do
      parent = self()

      runner = fn executable, args, _opts ->
        send(parent, {:cmd, executable, args})

        case {executable, args} do
          {"git", ["rev-list", "--count", _]} -> {"1\n", 0}
          _ -> flunk("unexpected command after invalid metadata: #{executable} #{inspect(args)}")
        end
      end

      assert {:error, %AutoPR.TaskMetadataError{field: :description, reason: :blank}} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-11",
                 base_branch: "main",
                 head_branch: "foreman/run-11/implement",
                 task_title: "Task title",
                 task_description: "   ",
                 command_runner: runner
               })

      assert_receive {:cmd, "git", ["rev-list", "--count", "main..foreman/run-11/implement"]}
      refute_receive {:cmd, "git", ["push", "-u", "origin", _]}
      refute_receive {:cmd, "gh", _}
    end

    test "preserves legacy generated body and review findings when no task metadata is present" do
      parent = self()

      artifact =
        Path.join(System.tmp_dir!(), "autopr-findings-#{System.unique_integer([:positive])}.md")

      File.write!(artifact, """
      report
      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      finding one
      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """)

      on_exit(fn -> File.rm_rf(artifact) end)

      runner = fn
        "git", ["rev-list", "--count", "main..foreman/run-12/implement"], _opts ->
          {"1\n", 0}

        "git", ["push", "-u", "origin", "foreman/run-12/implement"], _opts ->
          {"", 0}

        "gh", args, _opts ->
          send(parent, {:gh_args, args})
          {"https://github.com/acme/repo/pull/12\n", 0}
      end

      assert {:ok, _url} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-12",
                 base_branch: "main",
                 head_branch: "foreman/run-12/implement",
                 artifact_path: artifact,
                 command_runner: runner
               })

      assert_receive {:gh_args, args}
      body = Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)
      assert body =~ "Foreman run `run-12` complete."
      assert body =~ "Artifact: #{artifact}"
      assert body =~ "## Unresolved review findings"
      assert body =~ "finding one"
    end
  end

  describe "the base branch decides what the PR would contain" do
    # PR #420 opened with `--base=main` while the run had been cut from
    # `feat/mcp-run-details`, so its diff was an entire unrelated session of
    # commits. `commits_ahead/3` reads the same base `gh pr create` does, so
    # under the default branch a run that produced nothing still looks like it
    # has work to propose.
    test "a head level with its feature-branch base is a noop, though ahead of main", ctx do
      %{repo: repo, git: git} = ctx
      {_, 0} = git.(["checkout", "-b", "feat/mcp-run-details"])
      File.write!(Path.join(repo, "unrelated.txt"), "another session's commit\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "unrelated session work"])
      # The run's branch is cut from the feature branch and adds nothing to it.
      {_, 0} = git.(["branch", "foreman/run-8/create-prd"])

      assert AutoPR.maybe_create_pr(%{
               run_id: "run-8",
               base_branch: "feat/mcp-run-details",
               head_branch: "foreman/run-8/create-prd",
               cwd: repo
             }) == :noop

      # The same head against the default branch is one commit "ahead", and
      # every line of that commit belongs to the unrelated session. That is #420.
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

  describe "task metadata validation and log safety" do
    test "reports missing and invalid task metadata with typed errors" do
      runner = fn
        "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
        executable, args, _opts -> flunk("unexpected command: #{executable} #{inspect(args)}")
      end

      assert {:error, %AutoPR.TaskMetadataError{field: :title, reason: :invalid}} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-nil-title",
                 base_branch: "main",
                 head_branch: "foreman/run-nil-title/implement",
                 task_title: nil,
                 task_description: "Task body",
                 command_runner: runner
               })

      assert {:error, %AutoPR.TaskMetadataError{field: :title, reason: :invalid}} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-invalid-title",
                 base_branch: "main",
                 head_branch: "foreman/run-invalid-title/implement",
                 task_title: 123,
                 task_description: "Task body",
                 command_runner: runner
               })
    end

    test "does not write task body text in AutoPR success or validation logs" do
      parent = self()
      sentinel = "SECRET-SENTINEL-TASK-BODY"

      runner = fn
        "git", ["rev-list", "--count", _], _opts ->
          {"1\n", 0}

        "git", ["push", "-u", "origin", _], _opts ->
          {"", 0}

        "gh", args, _opts ->
          send(parent, {:gh_args, args})
          {"https://github.com/acme/repo/pull/13\n", 0}
      end

      log =
        capture_log(fn ->
          assert {:ok, _url} =
                   AutoPR.maybe_create_pr(%{
                     run_id: "run-log-safety",
                     base_branch: "main",
                     head_branch: "foreman/run-log-safety/implement",
                     task_title: "Task title",
                     task_description: sentinel,
                     command_runner: runner
                   })
        end)

      assert_receive {:gh_args, args}
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1) == sentinel
      refute log =~ sentinel
    end
  end
end
