defmodule ForemanServer.Workflow.AutoPRTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.AutoPR

  @sha "0123456789abcdef0123456789abcdef01234567"

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
      # `gh pr create`. This temp repo has no remote, so the push's intent cannot
      # read the remote head and the push does not run. The contract under test is
      # that it got past the decision and surfaced an error rather than silently
      # no-opping, which is what used to happen.
      assert {:error, reason} = AutoPR.maybe_create_pr(context)
      assert {:intent_not_recorded, {:remote_head_unreadable, _}} = reason
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

        "git", ["rev-parse", "--verify", _ref], _opts ->
          {@sha <> "\n", 0}

        "git", ["ls-remote", "origin", _ref], _opts ->
          {"", 0}

        "gh", ["pr", "list" | _], _opts ->
          {"[]", 0}

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
                 cwd: "/work/tree",
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

        "git", ["rev-parse", "--verify", _ref], _opts ->
          {@sha <> "\n", 0}

        "git", ["ls-remote", "origin", _ref], _opts ->
          {"", 0}

        "gh", ["pr", "list" | _], _opts ->
          {"[]", 0}

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
                 cwd: "/work/tree",
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

        "git", ["rev-parse", "--verify", _ref], _opts ->
          {@sha <> "\n", 0}

        "git", ["ls-remote", "origin", _ref], _opts ->
          {"", 0}

        "gh", ["pr", "list" | _], _opts ->
          {"[]", 0}

        "gh", args, _opts ->
          send(parent, {:gh_args, args})
          {"https://github.com/acme/repo/pull/12\n", 0}
      end

      assert {:ok, _url} =
               AutoPR.maybe_create_pr(%{
                 run_id: "run-12",
                 base_branch: "main",
                 head_branch: "foreman/run-12/implement",
                 cwd: "/work/tree",
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

      assert {:intent_not_recorded, {:remote_head_unreadable, _}} = reason
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

      assert {:intent_not_recorded, {:remote_head_unreadable, _}} = reason
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

        "git", ["rev-parse", "--verify", _ref], _opts ->
          {@sha <> "\n", 0}

        "git", ["ls-remote", "origin", _ref], _opts ->
          {"", 0}

        "gh", ["pr", "list" | _], _opts ->
          {"[]", 0}

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
                     cwd: "/work/tree",
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

defmodule ForemanServer.Workflow.AutoPREffectsTest do
  @moduledoc """
  The push and the PR create of `AutoPR.maybe_create_pr/1` are keyed effects
  (TRD-013): the intent is recorded before each, a crash on either side of one is
  reconciled by the boot sweep (a push against the remote branch, a PR create against
  GitHub) and no second `git push` or `gh pr create` is issued for an effect that
  already happened. Real git with a bare `origin`; `gh` is scripted
  (`ForemanServer.TestSupport.EffectWorld`).
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.{BranchPush, PrCreate}
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.Workflow.AutoPR

  @project_id "project-autopr-effects"

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "autopr-effects-project-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    :ok = EffectWorld.register_project!(@project_id, path)
  end

  setup do
    KeyStoreReset.reset!()
    on_exit(&KeyStoreReset.reset!/0)

    run_id = EffectWorld.start_run!(@project_id, "autopr-effects")
    fx = EffectWorld.fixture!("foreman/#{run_id}/implement")
    world = EffectWorld.start()

    ctx = %{
      run_id: run_id,
      base_branch: fx.base,
      head_branch: fx.head,
      cwd: fx.repo,
      command_runner: EffectWorld.runner(world)
    }

    {:ok,
     run_id: run_id,
     fx: fx,
     world: world,
     ctx: ctx,
     push_key: BranchPush.key(run_id, fx.head),
     create_key: PrCreate.key(run_id, fx.head, fx.base)}
  end

  # What the run's executor does on resumption. A blocked run is cancelled by the
  # sweep and never gets here.
  defp resume_unless_blocked(run_id, ctx),
    do: if(EffectWorld.status(run_id) != "blocked", do: AutoPR.maybe_create_pr(ctx))

  # The status an undecided key has: `started` as the dead process left it, or `ambiguous`
  # as the boot sweep marks it before it has decided it.
  defp undecided!(_key, :started), do: :ok
  defp undecided!(key, :ambiguous), do: :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")

  # The commands asked of the world. `git ls-remote` is asked by the push's intent (once per
  # attempt, before the PR lookup) and by the reconciler; `gh pr list` by AutoPR's lookups
  # (`--state open`) and by the reconciler (`--state all`).
  defp calls(world, "git", subcommand),
    do: for({"git", [^subcommand | _] = args, opts} <- EffectWorld.calls(world), do: {args, opts})

  defp pr_list_calls(world, state) do
    for {"gh", ["pr", "list" | _] = args, opts} <- EffectWorld.calls(world),
        ["--state", state] in Enum.chunk_every(args, 2, 1, :discard),
        do: {args, opts}
  end

  describe "the effects run through Effect.run" do
    test "the push intent holds both SHAs and the cwd before the push, and the key completes",
         %{ctx: ctx, fx: fx, run_id: run_id, push_key: key} do
      test = self()
      world_runner = ctx.command_runner

      runner = fn
        "git", ["push" | _] = args, opts ->
          send(test, {:key_during_push, KeyStore.get(key)})
          world_runner.("git", args, opts)

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, _url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert_received {:key_during_push, {:ok, %{status: :started, metadata: meta}}}

      assert %{
               "run_id" => ^run_id,
               "effect_class" => "branch_push",
               "head_branch" => head,
               "cwd" => cwd,
               "pre_push_remote_sha" => nil,
               "pushed_local_sha" => pushed
             } = meta

      assert head == fx.head
      assert cwd == fx.repo
      assert pushed == EffectWorld.local_tip(fx)
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "the push intent records the remote head as it stands", %{
      ctx: ctx,
      fx: fx,
      push_key: key
    } do
      EffectWorld.publish!(fx)
      old_tip = EffectWorld.local_tip(fx)
      new_tip = EffectWorld.commit_on_head!(fx, "more.txt")
      test = self()
      world_runner = ctx.command_runner

      runner = fn
        "git", ["push" | _] = args, opts ->
          send(test, {:key_during_push, KeyStore.get(key)})
          world_runner.("git", args, opts)

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, _url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert_received {:key_during_push, {:ok, %{metadata: meta}}}
      assert meta["pre_push_remote_sha"] == old_tip
      assert meta["pushed_local_sha"] == new_tip
    end

    test "the PR-create intent holds the cwd, head and base before gh pr create, and the key completes",
         %{ctx: ctx, fx: fx, run_id: run_id, create_key: key} do
      test = self()
      world_runner = ctx.command_runner

      runner = fn
        "gh", ["pr", "create" | _] = args, opts ->
          send(test, {:key_during_create, KeyStore.get(key)})
          world_runner.("gh", args, opts)

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, _url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert_received {:key_during_create, {:ok, %{status: :started, metadata: meta}}}

      assert %{
               "run_id" => ^run_id,
               "effect_class" => "pr_create",
               "head_branch" => head,
               "base_branch" => base,
               "cwd" => cwd
             } = meta

      assert {head, base, cwd} == {fx.head, fx.base, fx.repo}
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "a push that runs and fails keeps its error, marks its key failed and opens no PR",
         %{ctx: ctx, world: world, push_key: push_key} do
      world_runner = ctx.command_runner

      runner = fn
        "git", ["push" | _], _opts -> {"rejected", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, {:git_push_failed, 1, "rejected"}} =
               AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert {:ok, %{status: :failed}} = KeyStore.get(push_key)
      assert EffectWorld.executed(world, :create) == 0
    end

    test "a PR create that runs and fails keeps its error and marks its key failed",
         %{ctx: ctx, world: world, push_key: push_key, create_key: create_key} do
      world_runner = ctx.command_runner

      runner = fn
        "gh", ["pr", "create" | _], _opts -> {"boom", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, {:gh_pr_create_failed, 1, "boom"}} =
               AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      # GitHub was asked before the create and once more after its failure, and had no PR.
      assert [_before, _after] = pr_list_calls(world, "open")
      assert {:ok, %{status: :completed}} = KeyStore.get(push_key)
      assert {:ok, %{status: :failed}} = KeyStore.get(create_key)
    end

    test "a context with no cwd pushes nothing and opens no PR: the intent cannot be recorded",
         %{ctx: ctx, push_key: push_key, create_key: create_key} do
      test = self()

      runner = fn executable, args, opts ->
        send(test, {:ran, executable, args, opts})

        case {executable, args} do
          {"git", ["rev-list" | _]} -> {"1\n", 0}
          other -> flunk("unexpected command #{inspect(other)}")
        end
      end

      assert {:error, {:intent_not_recorded, :cwd_missing}} =
               AutoPR.maybe_create_pr(%{Map.delete(ctx, :cwd) | command_runner: runner})

      assert_received {:ran, "git", ["rev-list" | _], _}
      refute_received {:ran, _, _, _}
      assert :not_found = KeyStore.get(push_key)
      assert :not_found = KeyStore.get(create_key)
    end

    test "a remote head that cannot be read means the push does not run, and there is no tip to look a PR up by",
         %{ctx: ctx, fx: fx, world: world, push_key: push_key} do
      EffectWorld.break_origin!(fx)

      assert {:error, {:intent_not_recorded, {:remote_head_unreadable, _}}} =
               AutoPR.maybe_create_pr(ctx)

      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.executed(world, :create) == 0
      assert pr_list_calls(world, "open") == []
      assert :not_found = KeyStore.get(push_key)
    end
  end

  describe "a key nobody has decided" do
    for status <- [:started, :ambiguous] do
      test "a #{status} push key: the refusal comes back, logged as not run and naming the key",
           %{ctx: ctx, world: world, push_key: push_key} do
        EffectWorld.crash!(world, :push, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
        undecided!(push_key, unquote(status))
        {:ok, before_key} = KeyStore.get(push_key)

        log =
          capture_log(fn ->
            assert {:error, {:effect_undecided, ^push_key}} = AutoPR.maybe_create_pr(ctx)
          end)

        assert log =~ "git push NOT run"
        assert log =~ push_key
        assert EffectWorld.executed(world, :push) == 0
        assert EffectWorld.executed(world, :create) == 0
        assert {:ok, ^before_key} = KeyStore.get(push_key)
      end

      test "a #{status} PR-create key stops the sequence before the push: the push is not repeated either",
           %{ctx: ctx, world: world, create_key: create_key} do
        # The push goes through once; the create then dies before it reaches GitHub.
        EffectWorld.crash!(world, :create, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
        assert EffectWorld.executed(world, :push) == 1
        undecided!(create_key, unquote(status))
        {:ok, before_key} = KeyStore.get(create_key)

        log =
          capture_log(fn ->
            assert {:error, {:effect_undecided, ^create_key}} = AutoPR.maybe_create_pr(ctx)
          end)

        assert log =~ "git push and gh pr create NOT run"
        assert log =~ create_key
        assert EffectWorld.executed(world, :push) == 1
        assert EffectWorld.executed(world, :create) == 0
        assert EffectWorld.prs(world) == []
        assert {:ok, ^before_key} = KeyStore.get(create_key)
      end
    end

    test "a PR-create key that turns undecided while the push runs is refused by the create itself",
         %{ctx: ctx, fx: fx, world: world, run_id: run_id, create_key: create_key} do
      world_runner = ctx.command_runner

      # Another attempt starts the PR create while this one pushes: the preflight read a
      # clear key, the create's own check finds it started.
      runner = fn
        "git", ["push" | _] = args, opts ->
          result = world_runner.("git", args, opts)

          :ok =
            KeyStore.mark_started(create_key, %{
              "run_id" => run_id,
              "effect_class" => "pr_create",
              "head_branch" => fx.head,
              "base_branch" => fx.base,
              "cwd" => fx.repo
            })

          result

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      log =
        capture_log(fn ->
          assert {:error, {:effect_undecided, ^create_key}} =
                   AutoPR.maybe_create_pr(%{ctx | command_runner: runner})
        end)

      assert log =~ "gh pr create NOT run"
      assert log =~ create_key
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
      assert EffectWorld.prs(world) == []
    end
  end

  describe "a crash on either side of the push" do
    test "after the push reached the remote: blocked, and no second push",
         %{ctx: ctx, fx: fx, world: world, run_id: run_id, push_key: key} do
      EffectWorld.crash!(world, :push, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, ctx)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
      assert {:ok, :ambiguous} = KeyStore.status(key)

      # The reconciler read the remote in the key's cwd.
      assert [{_, intent_opts}, {_, reconciler_opts}] = calls(world, "git", "ls-remote")
      assert intent_opts[:cd] == fx.repo
      assert reconciler_opts[:cd] == fx.repo
    end

    test "before the push reached the remote: retried, and the push runs once",
         %{ctx: ctx, fx: fx, world: world, run_id: run_id, push_key: key} do
      EffectWorld.crash!(world, :push, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert EffectWorld.remote_tip(fx) == nil

      EffectWorld.sweep(world)

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]
      assert {:ok, :ambiguous} = KeyStore.status(key)

      assert {:ok, _url} = resume_unless_blocked(run_id, ctx)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end

  describe "a crash on either side of gh pr create" do
    test "after GitHub made the PR: blocked, and no second PR",
         %{ctx: ctx, fx: fx, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :create) == 1

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, ctx)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
      assert length(EffectWorld.prs(world)) == 1
      assert {:ok, :ambiguous} = KeyStore.status(key)

      # The query names the head and base, covers every state and runs in the key's cwd.
      assert [{args, opts}] = pr_list_calls(world, "all")
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--state", "all"])
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--head", fx.head])
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--base", fx.base])
      assert opts[:cd] == fx.repo
    end

    test "after GitHub made the PR and it was merged before recovery ran: still blocked, no second PR",
         %{ctx: ctx, world: world, run_id: run_id} do
      EffectWorld.crash!(world, :create, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      EffectWorld.merge_prs!(world)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, ctx)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
    end

    test "before gh pr create ran: retried, and the PR is created once",
         %{ctx: ctx, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert EffectWorld.executed(world, :create) == 0
      assert EffectWorld.prs(world) == []

      EffectWorld.sweep(world)

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]

      assert {:ok, url} = resume_unless_blocked(run_id, ctx)

      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert EffectWorld.executed(world, :create) == 1
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a GitHub that cannot be queried blocks the run as ambiguous and creates nothing more",
         %{ctx: ctx, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      EffectWorld.fail_gh_list!(world)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, ctx)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_outcome_ambiguous"
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end
  end

  # --- a PR GitHub already has for the run's head (TRD-004) ----------------------------------

  # An open PR of this repository for the run's head and base, as GitHub reports it: its head is
  # the local tip unless `report` says otherwise.
  defp open_pr!(world, fx, report \\ []) do
    url = EffectWorld.add_pr!(world, fx.head, fx.base)

    :ok =
      EffectWorld.report_pr!(
        world,
        url,
        Keyword.merge([head_sha: EffectWorld.local_tip(fx), cross_repository: false], report)
      )

    url
  end

  # GitHub refuses a second open PR for a head and base that already have one: `gh pr create`
  # exits 1 and says where the PR is. Every attempt is told to the test.
  defp refusing_duplicates(world, fx) do
    test = self()
    world_runner = EffectWorld.runner(world)

    fn
      "gh", ["pr", "create" | _] = args, opts ->
        send(test, {:create_attempt, args})

        existing =
          Enum.find(
            EffectWorld.prs(world),
            &(&1["state"] == "OPEN" and &1["head"] == fx.head and &1["base"] == fx.base)
          )

        case existing do
          %{"url" => url} ->
            {"a pull request for branch \"#{fx.head}\" into branch \"#{fx.base}\" already exists:\n#{url}\n",
             1}

          nil ->
            world_runner.("gh", args, opts)
        end

      executable, args, opts ->
        world_runner.(executable, args, opts)
    end
  end

  defp create_meta(ctx, fx) do
    %{
      "run_id" => ctx.run_id,
      "effect_class" => "pr_create",
      "head_branch" => fx.head,
      "base_branch" => fx.base,
      "cwd" => fx.repo
    }
  end

  # What an earlier attempt left on the PR-create key: `started` as a dead process leaves it,
  # `ambiguous` as the sweep marks it, `decided` once it has decided `not_done`, `unresolved`
  # once it could not resolve it (a `done` verdict on a run it cannot block).
  defp leave_create_key!(_c, :absent), do: :ok

  defp leave_create_key!(%{ctx: ctx, fx: fx, create_key: key}, status) do
    :ok = KeyStore.mark_started(key, create_meta(ctx, fx))
    settle_key!(key, status)
  end

  defp settle_key!(_key, :started), do: :ok

  defp settle_key!(key, :ambiguous),
    do: :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")

  defp settle_key!(key, :decided) do
    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
    :ok = KeyStore.mark_decided(key, :not_done)
  end

  defp settle_key!(key, :unresolved) do
    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
    :ok = KeyStore.mark_unresolved(key, 5, "effect_already_done")
  end

  defp settle_key!(key, :completed), do: :ok = KeyStore.mark_completed(key)
  defp settle_key!(key, :failed), do: :ok = KeyStore.mark_failed(key, "boom")

  defp assert_adopted_key(key, :absent), do: assert(:not_found = KeyStore.get(key))

  defp assert_adopted_key(key, _left_by_an_earlier_attempt) do
    assert {:ok, %{status: :completed, metadata: metadata}} = KeyStore.get(key)
    # What recovery wrote on the key goes with it, so a later attempt does not inherit it.
    assert KeyStore.unresolved_version(metadata) == :none
    assert KeyStore.decision(metadata) == :none
  end

  describe "a PR GitHub already has for the run's head" do
    for status <- [:absent, :started, :ambiguous, :decided, :unresolved] do
      test "the open PR whose head is the local tip is the answer, with no preflight, push or gh pr create (create key: #{status})",
           %{ctx: ctx, fx: fx, world: world, create_key: create_key, push_key: push_key} = c do
        url = open_pr!(world, fx)
        leave_create_key!(c, unquote(status))

        log = capture_log(fn -> assert {:ok, ^url} = AutoPR.maybe_create_pr(ctx) end)

        assert log =~ "adopted #{url}"
        assert EffectWorld.executed(world, :push) == 0
        assert EffectWorld.executed(world, :create) == 0
        assert :not_found = KeyStore.get(push_key)
        assert_adopted_key(create_key, unquote(status))

        # GitHub is asked once, in the checkout, among the open PRs for this head and base.
        assert [{args, opts}] = pr_list_calls(world, "open")
        pairs = Enum.chunk_every(args, 2, 1, :discard)
        assert ["--head", fx.head] in pairs
        assert ["--base", fx.base] in pairs
        assert opts[:cd] == fx.repo
      end
    end

    for status <- [:completed, :failed] do
      test "a settled create key (#{status}) is left as it is",
           %{ctx: ctx, fx: fx, world: world, create_key: create_key} = c do
        url = open_pr!(world, fx)
        leave_create_key!(c, unquote(status))
        {:ok, before_key} = KeyStore.get(create_key)

        assert {:ok, ^url} = AutoPR.maybe_create_pr(ctx)

        assert {:ok, ^before_key} = KeyStore.get(create_key)
      end
    end

    test "the PR a dead attempt made is adopted by the next one, before any sweep has decided its key",
         %{ctx: ctx, fx: fx, world: world, create_key: create_key} do
      EffectWorld.crash!(world, :create, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert {:ok, :started} = KeyStore.status(create_key)
      assert [%{"url" => url}] = EffectWorld.prs(world)

      # GitHub knows the head of the PR it made: the commit that was pushed.
      :ok =
        EffectWorld.report_pr!(world, url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      assert {:ok, ^url} = AutoPR.maybe_create_pr(ctx)

      assert {:ok, :completed} = KeyStore.status(create_key)
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 1
    end

    test "a fork's PR of the same branch name is not adopted, though its head is the tip: the run gets a PR of its own",
         %{ctx: ctx, fx: fx, world: world, push_key: push_key, create_key: create_key} do
      fork_url = open_pr!(world, fx, cross_repository: true)

      assert {:ok, url} = AutoPR.maybe_create_pr(ctx)

      refute url == fork_url
      assert [%{"url" => ^fork_url}, %{"url" => ^url}] = EffectWorld.prs(world)
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 1
      assert {:ok, :completed} = KeyStore.status(push_key)
      assert {:ok, :completed} = KeyStore.status(create_key)
    end

    test "a closed PR of the head is not adopted: only an open one is the run's, so it gets a PR of its own",
         %{ctx: ctx, fx: fx, world: world} do
      closed_url = EffectWorld.add_pr!(world, fx.head, fx.base, "CLOSED")

      :ok =
        EffectWorld.report_pr!(world, closed_url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      assert {:ok, url} = AutoPR.maybe_create_pr(ctx)

      refute url == closed_url
      assert EffectWorld.executed(world, :create) == 1
    end

    test "a PR of this repository with another head is not adopted: GitHub refuses the duplicate and the typed mismatch names the PR and both heads",
         %{ctx: ctx, fx: fx, world: world, create_key: create_key} do
      other = String.duplicate("a", 40)
      url = open_pr!(world, fx, head_sha: other)
      tip = EffectWorld.local_tip(fx)
      runner = refusing_duplicates(world, fx)

      log =
        capture_log(fn ->
          assert {:error, {:pr_lookup_mismatch, ^url, ^tip, ^other}} =
                   AutoPR.maybe_create_pr(%{ctx | command_runner: runner})
        end)

      assert log =~ "not adopted"
      assert_received {:create_attempt, _args}
      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert EffectWorld.executed(world, :push) == 1
      assert [_before, _after] = pr_list_calls(world, "open")
      assert {:ok, %{status: :failed}} = KeyStore.get(create_key)
    end

    test "a push that moves the PR's head to the tip: the duplicate create is refused and the second lookup adopts the PR, the key completed",
         %{ctx: ctx, fx: fx, world: world, create_key: create_key} do
      url = open_pr!(world, fx, head_sha: String.duplicate("a", 40))
      tip = EffectWorld.local_tip(fx)
      refuser = refusing_duplicates(world, fx)

      runner = fn
        "git", ["push" | _] = args, opts ->
          result = refuser.("git", args, opts)
          # Pushing the branch moves the head of the PR that is open for it.
          :ok = EffectWorld.report_pr!(world, url, head_sha: tip)
          result

        executable, args, opts ->
          refuser.(executable, args, opts)
      end

      assert {:ok, ^url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert_received {:create_attempt, _args}
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
      assert {:ok, :completed} = KeyStore.status(create_key)
    end

    test "gh pr create exits non-zero because the PR appeared since the lookup: the second lookup adopts it and the key settles completed, not failed",
         %{ctx: ctx, fx: fx, world: world, create_key: create_key} do
      test = self()
      world_runner = ctx.command_runner

      runner = fn
        "gh", ["pr", "create" | _], _opts ->
          # Another attempt's create reached GitHub between this one's lookup and its create.
          url = open_pr!(world, fx)
          send(test, {:made_meanwhile, url})

          {"a pull request for branch \"#{fx.head}\" into branch \"#{fx.base}\" already exists:\n#{url}\n",
           1}

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert_received {:made_meanwhile, ^url}
      assert [_before, _after] = pr_list_calls(world, "open")
      assert EffectWorld.executed(world, :create) == 0
      assert {:ok, :completed} = KeyStore.status(create_key)
    end

    @unusable_answers [
      {"a non-zero exit", {"error connecting to api.github.com\n", 1}},
      {"text that is not JSON", {"gh: something odd\n", 0}},
      {"JSON that is not a list", {~s({"message": "Not Found"}), 0}},
      {"PRs listed without their head",
       {~s([{"url": "https://github.com/acme/widgets/pull/1", "number": 1, "state": "OPEN"}]), 0}}
    ]

    for {name, reply} <- @unusable_answers do
      test "a lookup that gets #{name} is a failed lookup, never a PR: gh pr create runs and has its say",
           %{ctx: ctx, world: world, create_key: create_key} do
        reply = unquote(Macro.escape(reply))
        world_runner = ctx.command_runner

        runner = fn
          "gh", ["pr", "list" | _], _opts -> reply
          executable, args, opts -> world_runner.(executable, args, opts)
        end

        log =
          capture_log(fn ->
            assert {:ok, url} = AutoPR.maybe_create_pr(%{ctx | command_runner: runner})
            assert [%{"url" => ^url}] = EffectWorld.prs(world)
          end)

        assert log =~ "no PR adopted"
        assert EffectWorld.executed(world, :push) == 1
        assert EffectWorld.executed(world, :create) == 1
        assert {:ok, :completed} = KeyStore.status(create_key)
      end
    end

    test "a lookup that fails twice leaves gh pr create's own error, and the key failed",
         %{ctx: ctx, world: world, create_key: create_key} do
      EffectWorld.fail_gh_list!(world)
      world_runner = ctx.command_runner

      runner = fn
        "gh", ["pr", "create" | _], _opts -> {"boom", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, {:gh_pr_create_failed, 1, "boom"}} =
               AutoPR.maybe_create_pr(%{ctx | command_runner: runner})

      assert [_before, _after] = pr_list_calls(world, "open")
      assert {:ok, %{status: :failed}} = KeyStore.get(create_key)
    end
  end
end
