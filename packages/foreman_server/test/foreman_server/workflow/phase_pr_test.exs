defmodule ForemanServer.Workflow.PhasePRTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PhasePR

  @sha "0123456789abcdef0123456789abcdef01234567"

  defp request(overrides \\ %{}) do
    struct!(
      PhasePR.Request,
      Map.merge(
        %{
          run_id: "run-1",
          phase_id: "phase-1",
          phase_index: 1,
          phase_name: "implement",
          base_branch: "main",
          head_branch: "foreman/run-1",
          cwd: "/repo",
          now: ~U[2026-09-01 00:00:00Z],
          command_runner: &runner/3
        },
        overrides
      )
    )
  end

  test "returns noop when head has no commits beyond base" do
    assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner_with_ahead(0)}))
    assert record.status == "noop"
    assert record.reason == "no_commits_ahead"
    assert record.pr_url == nil
  end

  test "created path pushes and opens a GitHub PR" do
    assert {:ok, record} = PhasePR.maybe_create(request())
    assert record.status == "created"
    assert record.pr_url == "https://github.com/acme/repo/pull/42"
    assert record.pr_number == 42
    assert record.base_branch == "main"
    assert record.head_branch == "foreman/run-1"
  end

  test "reuses an existing open head/base PR after pushing head" do
    open_json = ~s([{"url":"https://github.com/acme/repo/pull/7","number":7}])
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn
      executable, args, _opts ->
        Agent.update(calls, &[{executable, args} | &1])

        case {executable, args} do
          {"git", ["rev-list", "--count", _]} -> {"1\n", 0}
          {"git", ["rev-parse", "--verify", _ref]} -> {@sha <> "\n", 0}
          {"git", ["ls-remote", "origin", _ref]} -> {"", 0}
          {"git", ["push", "-u", "origin", "foreman/run-1"]} -> {"Everything up-to-date\n", 0}
          {"gh", ["pr", "list", "--state", "open" | _]} -> {open_json, 0}
        end
    end

    assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner}))
    assert record.status == "existing"
    assert record.pr_url == "https://github.com/acme/repo/pull/7"

    assert [{"git", ["push", "-u", "origin", "foreman/run-1"]}] =
             calls
             |> Agent.get(&Enum.reverse/1)
             |> Enum.filter(fn {executable, args} ->
               executable == "git" and Enum.take(args, 1) == ["push"]
             end)
  end

  test "three sequential stack PR phases push cumulative branch state" do
    {repo, remote} = git_fixture!()
    {:ok, gh_state} = Agent.start_link(fn -> %{open?: false} end)
    {:ok, pushes} = Agent.start_link(fn -> [] end)
    runner = git_runner_with_fake_gh(gh_state, pushes)

    Enum.each(1..3, fn index ->
      write_phase_commit!(repo, index)

      assert {:ok, record} =
               PhasePR.maybe_create(
                 request(%{
                   phase_id: "phase-#{index}",
                   phase_index: index,
                   phase_name: "phase-#{index}",
                   cwd: repo,
                   command_runner: runner
                 })
               )

      assert record.status in ["created", "existing"]
    end)

    assert Agent.get(pushes, &Enum.reverse/1) == [
             ["push", "-u", "origin", "foreman/run-1"],
             ["push", "-u", "origin", "foreman/run-1"],
             ["push", "-u", "origin", "foreman/run-1"]
           ]

    assert {"3\n", 0} =
             System.cmd("git", [
               "--git-dir",
               remote,
               "rev-list",
               "--count",
               "main..refs/heads/foreman/run-1"
             ])
  end

  test "closed matching PR is a typed error" do
    closed_json = ~s([{"url":"https://github.com/acme/repo/pull/8","number":8}])

    runner = fn
      "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
      "git", ["rev-parse", "--verify", _ref], _opts -> {@sha <> "\n", 0}
      "git", ["ls-remote", "origin", _ref], _opts -> {"", 0}
      "git", ["push", "-u", "origin", "foreman/run-1"], _opts -> {"", 0}
      "gh", ["pr", "list", "--state", "open" | _], _opts -> {"[]", 0}
      "gh", ["pr", "list", "--state", "closed" | _], _opts -> {closed_json, 0}
    end

    assert {:error, %PhasePR.Error{reason: :matching_pr_closed}} =
             PhasePR.maybe_create(request(%{command_runner: runner}))
  end

  test "missing head branch is typed" do
    assert {:error, %PhasePR.Error{reason: :phase_pr_head_branch_unresolved}} =
             PhasePR.maybe_create(request(%{head_branch: ""}))
  end

  defp runner_with_ahead(count) do
    fn
      "git", ["rev-list", "--count", _], _opts -> {"#{count}\n", 0}
    end
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "foreman-phase-pr-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "remote.git")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "--bare", remote])
    git!(root, ["init", repo])
    git!(repo, ["config", "user.email", "foreman@example.com"])
    git!(repo, ["config", "user.name", "Foreman Test"])
    git!(repo, ["checkout", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "base"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "-u", "origin", "main"])
    git!(repo, ["checkout", "-b", "foreman/run-1"])

    {repo, remote}
  end

  defp write_phase_commit!(repo, index) do
    path = Path.join(repo, "phase-#{index}.txt")
    File.write!(path, "phase #{index}\n")
    git!(repo, ["add", Path.basename(path)])
    git!(repo, ["commit", "-m", "phase #{index}"])
  end

  defp git_runner_with_fake_gh(gh_state, pushes) do
    fn
      "git", ["push" | _] = args, opts ->
        Agent.update(pushes, &[args | &1])
        System.cmd("git", args, opts)

      "git", args, opts ->
        System.cmd("git", args, opts)

      "gh", ["pr", "list", "--state", "open" | _], _opts ->
        if Agent.get(gh_state, & &1.open?) do
          {~s([{"url":"https://github.com/acme/repo/pull/7","number":7}]), 0}
        else
          {"[]", 0}
        end

      "gh", ["pr", "list", "--state", "closed" | _], _opts ->
        {"[]", 0}

      "gh", ["pr", "create" | _], _opts ->
        Agent.update(gh_state, &%{&1 | open?: true})
        {"https://github.com/acme/repo/pull/7\n", 0}
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> flunk("git #{Enum.join(args, " ")} failed (#{exit_code}): #{output}")
    end
  end

  defp runner("git", ["rev-list", "--count", _], _opts), do: {"1\n", 0}
  defp runner("git", ["rev-parse", "--verify", _ref], _opts), do: {@sha <> "\n", 0}
  defp runner("git", ["ls-remote", "origin", _ref], _opts), do: {"", 0}
  defp runner("gh", ["pr", "list", _state_flag, _state | _], _opts), do: {"[]", 0}
  defp runner("git", ["push", "-u", "origin", "foreman/run-1"], _opts), do: {"", 0}

  defp runner("gh", ["pr", "create" | _], _opts),
    do: {"https://github.com/acme/repo/pull/42\n", 0}
end

defmodule ForemanServer.Workflow.PhasePREffectsTest do
  @moduledoc """
  The push and the PR create of `PhasePR.maybe_create/1` are keyed effects (TRD-013):
  the intent is recorded before each, a crash on either side of one is reconciled by the
  boot sweep (a push against the remote branch, a PR create against GitHub) and no second
  `git push` or `gh pr create` is issued for an effect that already happened. Real git
  with a bare `origin`; `gh` is scripted (`ForemanServer.TestSupport.EffectWorld`), and
  reaches `PhasePR` through the request's `command_runner`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.{BranchPush, PrCreate}
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.Workflow.PhasePR

  @project_id "project-phase-pr-effects"

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "phase-pr-effects-project-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    :ok = EffectWorld.register_project!(@project_id, path)
  end

  setup do
    KeyStoreReset.reset!()
    on_exit(&KeyStoreReset.reset!/0)

    run_id = EffectWorld.start_run!(@project_id, "phase-pr-effects")
    fx = EffectWorld.fixture!("foreman/#{run_id}/implement")
    world = EffectWorld.start()

    request = %PhasePR.Request{
      run_id: run_id,
      phase_id: "phase-1",
      phase_index: 1,
      phase_name: "implement",
      base_branch: fx.base,
      head_branch: fx.head,
      cwd: fx.repo,
      now: ~U[2026-09-01 00:00:00Z],
      command_runner: EffectWorld.runner(world)
    }

    {:ok,
     run_id: run_id,
     fx: fx,
     world: world,
     request: request,
     push_key: BranchPush.key(run_id, fx.head),
     create_key: PrCreate.key(run_id, fx.head, fx.base)}
  end

  # What the run's executor does on resumption. A blocked run is cancelled by the
  # sweep and never gets here.
  defp resume_unless_blocked(run_id, request),
    do: if(EffectWorld.status(run_id) != "blocked", do: PhasePR.maybe_create(request))

  defp calls(world, "git", subcommand),
    do: for({"git", [^subcommand | _] = args, opts} <- EffectWorld.calls(world), do: {args, opts})

  # The `gh pr list` calls that asked for `state` (the reconciler's is `--state all`;
  # `PhasePR` itself asks `open` and `closed` one call each).
  defp pr_list_calls(world, state) do
    for {"gh", ["pr", "list" | rest] = args, opts} <- EffectWorld.calls(world),
        ["--state", state] in Enum.chunk_every(rest, 2, 1, :discard),
        do: {args, opts}
  end

  describe "the effects run through Effect.run" do
    test "the push intent holds both SHAs and the cwd before the push, and the key completes",
         %{request: request, fx: fx, run_id: run_id, push_key: key} do
      test = self()
      world_runner = request.command_runner

      runner = fn
        "git", ["push" | _] = args, opts ->
          send(test, {:key_during_push, KeyStore.get(key)})
          world_runner.("git", args, opts)

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, %PhasePR.Record{status: "created"}} =
               PhasePR.maybe_create(%{request | command_runner: runner})

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

    test "the PR-create intent holds the cwd, head and base before gh pr create, and the key completes",
         %{request: request, fx: fx, run_id: run_id, create_key: key} do
      test = self()
      world_runner = request.command_runner

      runner = fn
        "gh", ["pr", "create" | _] = args, opts ->
          send(test, {:key_during_create, KeyStore.get(key)})
          world_runner.("gh", args, opts)

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, %PhasePR.Record{status: "created"}} =
               PhasePR.maybe_create(%{request | command_runner: runner})

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

    test "a push that runs and fails keeps its typed error, marks its key failed and opens no PR",
         %{request: request, world: world, push_key: push_key} do
      world_runner = request.command_runner

      runner = fn
        "git", ["push" | _], _opts -> {"rejected", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, %PhasePR.Error{reason: :git_push_failed, details: details}} =
               PhasePR.maybe_create(%{request | command_runner: runner})

      assert details == %{exit_code: 1, output: "rejected"}
      assert {:ok, %{status: :failed}} = KeyStore.get(push_key)
      assert EffectWorld.executed(world, :create) == 0
    end

    test "a PR create that runs and fails keeps its typed error and marks its key failed",
         %{request: request, push_key: push_key, create_key: create_key} do
      world_runner = request.command_runner

      runner = fn
        "gh", ["pr", "create" | _], _opts -> {"boom", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, %PhasePR.Error{reason: :gh_pr_create_failed, details: details}} =
               PhasePR.maybe_create(%{request | command_runner: runner})

      assert details == %{exit_code: 1, output: "boom"}
      assert {:ok, %{status: :completed}} = KeyStore.get(push_key)
      assert {:ok, %{status: :failed}} = KeyStore.get(create_key)
    end

    test "a remote head that cannot be read is a typed error and the push does not run",
         %{request: request, fx: fx, world: world, push_key: push_key} do
      EffectWorld.break_origin!(fx)

      assert {:error,
              %PhasePR.Error{
                reason: :intent_not_recorded,
                details: %{effect: :branch_push, reason: {:remote_head_unreadable, _}}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.executed(world, :create) == 0
      assert :not_found = KeyStore.get(push_key)
    end

    test "a push key recovery left unresolved is refused with a typed error and not repeated",
         %{request: request, world: world, run_id: run_id, push_key: push_key} do
      :ok =
        KeyStore.mark_started(push_key, %{
          "run_id" => run_id,
          "effect_class" => "branch_push",
          "pushed_local_sha" => "abc"
        })

      :ok = KeyStore.mark_unresolved(push_key, 0, "effect_outcome_ambiguous")
      {:ok, before_key} = KeyStore.get(push_key)

      assert {:error,
              %PhasePR.Error{
                reason: :effect_unresolved,
                details: %{effect: :branch_push, key: ^push_key}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.executed(world, :create) == 0
      assert {:ok, ^before_key} = KeyStore.get(push_key)
    end
  end

  describe "a PR-create key recovery left unresolved" do
    test "refuses before the push: nothing is pushed or created", ctx do
      %{request: request, world: world, run_id: run_id, create_key: create_key} = ctx

      :ok =
        KeyStore.mark_started(create_key, %{
          "run_id" => run_id,
          "effect_class" => "pr_create"
        })

      :ok = KeyStore.mark_unresolved(create_key, 0, "effect_outcome_ambiguous")
      {:ok, before_key} = KeyStore.get(create_key)

      assert {:error,
              %PhasePR.Error{
                reason: :effect_unresolved,
                details: %{effect: :pr_create, key: ^create_key}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.executed(world, :create) == 0
      assert {:ok, ^before_key} = KeyStore.get(create_key)
    end

    test "a malformed marker is its own typed error and nothing runs", ctx do
      %{request: request, world: world, run_id: run_id, create_key: create_key} = ctx

      :ets.insert(
        :foreman_idempotency_keys,
        {create_key, :ambiguous,
         %{"run_id" => run_id, "effect_class" => "pr_create", "unresolved_at_run_version" => "x"}}
      )

      assert {:error,
              %PhasePR.Error{
                reason: :effect_marker_malformed,
                details: %{effect: :pr_create, key: ^create_key}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :push) == 0
    end

    test "a check that cannot be made is its own typed error and nothing runs", ctx do
      %{request: request, world: world, run_id: run_id, create_key: create_key} = ctx

      :ok =
        KeyStore.mark_started(create_key, %{"run_id" => run_id, "effect_class" => "pr_create"})

      :ok = KeyStore.mark_unresolved(create_key, 0, "effect_outcome_ambiguous")
      original = Application.get_env(:foreman_server, ForemanServer.Idempotency.Effect)

      Application.put_env(:foreman_server, ForemanServer.Idempotency.Effect,
        run_stream_reader: fn _stream, _from -> {:error, :boom} end
      )

      on_exit(fn ->
        if original,
          do: Application.put_env(:foreman_server, ForemanServer.Idempotency.Effect, original),
          else: Application.delete_env(:foreman_server, ForemanServer.Idempotency.Effect)
      end)

      assert {:error,
              %PhasePR.Error{
                reason: :effect_check_failed,
                details: %{effect: :pr_create, reason: :boom}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :push) == 0
    end
  end

  describe "a crash on either side of the push" do
    test "after the push reached the remote: blocked, and no second push",
         %{request: request, fx: fx, world: world, run_id: run_id, push_key: key} do
      EffectWorld.crash!(world, :push, :after, fn -> PhasePR.maybe_create(request) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, request)

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
         %{request: request, fx: fx, world: world, run_id: run_id, push_key: key} do
      EffectWorld.crash!(world, :push, :before, fn -> PhasePR.maybe_create(request) end)
      assert EffectWorld.remote_tip(fx) == nil

      EffectWorld.sweep(world)

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]
      assert {:ok, :ambiguous} = KeyStore.status(key)

      assert {:ok, %PhasePR.Record{status: "created"}} = resume_unless_blocked(run_id, request)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end

  describe "a crash on either side of gh pr create" do
    test "after GitHub made the PR: blocked, and no second PR",
         %{request: request, fx: fx, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :after, fn -> PhasePR.maybe_create(request) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :create) == 1

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, request)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
      assert length(EffectWorld.prs(world)) == 1
      assert {:ok, :ambiguous} = KeyStore.status(key)

      # The reconciler asked about every state, for the head and base, in the key's cwd.
      assert [{args, opts}] = pr_list_calls(world, "all")
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--head", fx.head])
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--base", fx.base])
      assert opts[:cd] == fx.repo
    end

    test "after GitHub made the PR and it was merged before recovery ran: still blocked, no second PR",
         %{request: request, world: world, run_id: run_id} do
      # `PhasePR` itself looks for an open or closed PR only, so a merged one is invisible to
      # a resumed attempt: only the reconciler stands between it and a second PR.
      EffectWorld.crash!(world, :create, :after, fn -> PhasePR.maybe_create(request) end)
      EffectWorld.merge_prs!(world)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, request)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
    end

    test "before gh pr create ran: retried, and the PR is created once",
         %{request: request, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :before, fn -> PhasePR.maybe_create(request) end)
      assert EffectWorld.executed(world, :create) == 0
      assert EffectWorld.prs(world) == []

      EffectWorld.sweep(world)

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]

      assert {:ok, %PhasePR.Record{status: "created", pr_url: url}} =
               resume_unless_blocked(run_id, request)

      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert EffectWorld.executed(world, :create) == 1
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a GitHub that cannot be queried blocks the run as ambiguous and creates nothing more",
         %{request: request, world: world, run_id: run_id, create_key: key} do
      EffectWorld.crash!(world, :create, :after, fn -> PhasePR.maybe_create(request) end)
      EffectWorld.merge_prs!(world)
      EffectWorld.fail_gh_list!(world)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, request)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_outcome_ambiguous"
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end
  end
end
