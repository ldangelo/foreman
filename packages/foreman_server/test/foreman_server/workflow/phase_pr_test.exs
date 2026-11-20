defmodule ForemanServer.Workflow.PhasePRTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias ForemanServer.GitHub.PrLookup
  alias ForemanServer.Workflow.PhasePR

  @sha "0123456789abcdef0123456789abcdef01234567"
  @other_sha "fedcba9876543210fedcba9876543210fedcba98"

  defp request(overrides \\ %{}) do
    struct!(
      PhasePR.Request,
      Map.merge(
        %{
          # Unique per request: the keyed effects of async tests must not meet.
          run_id: "run-#{System.unique_integer([:positive])}",
          phase_id: "phase-1",
          phase_index: 1,
          phase_name: "implement",
          base_branch: "main",
          head_branch: "foreman/run-1",
          cwd: "/repo",
          now: ~U[2026-09-01 00:00:00Z],
          lookup_retry_sleep_ms: 0,
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

  test "an open head/base PR that already has the tip is reused: nothing is pushed or created" do
    open_json = Jason.encode!([pr_item()])
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

    assert [] =
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

  describe "the PR GitHub already has (GitHub.PrLookup)" do
    test "an open PR of this repository whose head is the pushed tip is reused and no PR is created" do
      runner = scripted_runner(open: answer([pr_item()]))

      assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner}))
      assert record.status == "existing"
      assert record.pr_url == "https://github.com/acme/repo/pull/7"
      assert record.pr_number == 7

      # The lookup asked for this head and base, in the checkout.
      assert_received {:gh_pr_list, "open", list_args, list_opts}

      assert Enum.chunk_every(list_args, 2, 1, :discard)
             |> Enum.member?(["--head", "foreman/run-1"])

      assert Enum.chunk_every(list_args, 2, 1, :discard) |> Enum.member?(["--base", "main"])
      assert list_opts[:cd] == "/repo"

      refute_received {:gh_pr_create, _args}
      refute_received {:gh_pr_list, "closed", _args, _opts}
    end

    test "an open PR of this repository with another head is a typed mismatch naming the PR and both heads: nothing is reused or created" do
      runner = scripted_runner(open: answer([pr_item(%{"headRefOid" => @other_sha})]))

      assert {:error,
              %PhasePR.Error{
                reason: :pr_lookup_mismatch,
                phase_id: "phase-1",
                base_branch: "main",
                head_branch: "foreman/run-1",
                details: %{
                  url: "https://github.com/acme/repo/pull/7",
                  expected_head: @sha,
                  actual_head: @other_sha
                }
              }} = PhasePR.maybe_create(request(%{command_runner: runner}))

      refute_received {:gh_pr_create, _args}
      refute_received {:gh_pr_list, "closed", _args, _opts}
    end

    test "a fork's open PR of the same branch name is not reused, though its head is the tip: the run gets a PR of its own" do
      runner = scripted_runner(open: answer([pr_item(%{"isCrossRepository" => true})]))

      assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner}))
      assert record.status == "created"
      assert record.pr_url == "https://github.com/acme/repo/pull/42"
      assert_received {:gh_pr_create, _args}
    end

    test "a fork's open PR with another head is no mismatch either: it is dropped before heads are compared" do
      runner =
        scripted_runner(
          open: answer([pr_item(%{"isCrossRepository" => true, "headRefOid" => @other_sha})])
        )

      assert {:ok, %PhasePR.Record{status: "created"}} =
               PhasePR.maybe_create(request(%{command_runner: runner}))
    end

    test "this repository's open PR is found behind a fork's PR of the same branch name" do
      runner =
        scripted_runner(
          open:
            answer([
              pr_item(%{
                "number" => 9,
                "url" => "https://github.com/acme/repo/pull/9",
                "isCrossRepository" => true
              }),
              pr_item()
            ])
        )

      assert {:ok, %PhasePR.Record{status: "existing", pr_number: 7}} =
               PhasePR.maybe_create(request(%{command_runner: runner}))

      refute_received {:gh_pr_create, _args}
    end

    for {state, expected} <- [{"CLOSED", :closed}, {"MERGED", :merged}] do
      test "a #{String.downcase(state)} PR of this repository is the typed :matching_pr_closed error carrying the PR: no PR is created over it" do
        runner =
          scripted_runner(
            closed:
              answer([
                pr_item(%{
                  "number" => 8,
                  "url" => "https://github.com/acme/repo/pull/8",
                  "state" => unquote(state)
                })
              ])
          )

        assert {:error,
                %PhasePR.Error{
                  reason: :matching_pr_closed,
                  phase_id: "phase-1",
                  details: %PrLookup.Pr{
                    url: "https://github.com/acme/repo/pull/8",
                    number: 8,
                    state: unquote(expected),
                    head_sha: @sha
                  }
                }} = PhasePR.maybe_create(request(%{command_runner: runner}))

        assert_received {:gh_pr_list, "open", _args, _opts}
        assert_received {:gh_pr_list, "closed", _args, _opts}
        refute_received {:gh_pr_create, _args}
      end
    end

    test "the closed lookup compares no head: a closed PR with another head still refuses creation" do
      runner =
        scripted_runner(
          closed: answer([pr_item(%{"state" => "CLOSED", "headRefOid" => @other_sha})])
        )

      assert {:error, %PhasePR.Error{reason: :matching_pr_closed}} =
               PhasePR.maybe_create(request(%{command_runner: runner}))

      refute_received {:gh_pr_create, _args}
    end

    test "only a fork's closed PR does not refuse creation: it is not this repository's" do
      runner =
        scripted_runner(
          closed: answer([pr_item(%{"state" => "CLOSED", "isCrossRepository" => true})])
        )

      assert {:ok, %PhasePR.Record{status: "created"}} =
               PhasePR.maybe_create(request(%{command_runner: runner}))

      assert_received {:gh_pr_create, _args}
    end

    for {description, reply, reason} <- [
          {"text that is not JSON", {"not json at all", 0}, :unparsable_pr_list},
          {"an empty answer", {"", 0}, :unparsable_pr_list},
          {"JSON that is not a list", {~s({"message":"Not Found"}), 0},
           :unexpected_pr_list_payload},
          {"a PR without a head or a repository flag (the shape of the former lookup)",
           {~s([{"url":"https://github.com/acme/repo/pull/7","number":7}]), 0},
           :unexpected_pr_list_payload}
        ],
        lookup <- [:open, :closed] do
      test "#{description} from the #{lookup} lookup is the typed #{reason} error and nothing is created" do
        answers = [{unquote(lookup), unquote(Macro.escape(reply))}]
        runner = scripted_runner(answers)

        assert {:error, %PhasePR.Error{reason: unquote(reason), phase_id: "phase-1"}} =
                 PhasePR.maybe_create(request(%{command_runner: runner}))

        refute_received {:gh_pr_create, _args}
      end
    end

    test "the unexpected payload and the unparsable text are carried in the error details" do
      assert {:error,
              %PhasePR.Error{
                reason: :unexpected_pr_list_payload,
                details: %{"message" => "Not Found"}
              }} =
               PhasePR.maybe_create(
                 request(%{
                   command_runner: scripted_runner(open: {~s({"message":"Not Found"}), 0})
                 })
               )

      assert {:error, %PhasePR.Error{reason: :unparsable_pr_list, details: "not json at all"}} =
               PhasePR.maybe_create(
                 request(%{command_runner: scripted_runner(open: {"not json at all", 0})})
               )
    end

    test "a failed lookup before the effects is logged as not adopted, and the flow still reaches the lookup after the push" do
      import ExUnit.CaptureLog
      runner = scripted_runner(open: {"error connecting to api.github.com", 1})

      log =
        capture_log(fn ->
          assert {:error, %PhasePR.Error{reason: :pr_lookup_failed}} =
                   PhasePR.maybe_create(request(%{command_runner: runner}))
        end)

      assert log =~ "no PR adopted for foreman/run-1 into main"
      assert log =~ "gh_failed"
      # The lookup before the effects, and the one after the push that surfaces the error.
      assert_received {:gh_pr_list, "open", _args, _opts}
      assert_received {:gh_pr_list, "open", _args, _opts}
      refute_received {:gh_pr_create, _args}
    end

    for lookup <- [:open, :closed] do
      test "a #{lookup} lookup that exits non-zero is the typed :pr_lookup_failed: no PR is created over a PR that could not be looked up" do
        runner = scripted_runner([{unquote(lookup), {"error connecting to api.github.com", 1}}])

        assert {:error,
                %PhasePR.Error{
                  reason: :pr_lookup_failed,
                  details: %{
                    state: unquote(lookup),
                    reason: {:gh_failed, 1, "error connecting to api.github.com"}
                  }
                }} = PhasePR.maybe_create(request(%{command_runner: runner}))

        refute_received {:gh_pr_create, _args}
      end

      test "a #{lookup} lookup that runs out of time is the typed :pr_lookup_failed with the timeout" do
        test = self()

        slow = fn
          "gh", ["pr", "list", "--state", state | _], _opts ->
            if state == unquote(Atom.to_string(lookup)), do: Process.sleep(2_000)
            {"[]", 0}

          "gh", ["pr", "create" | _], _opts ->
            send(test, :gh_pr_create)
            {"https://github.com/acme/repo/pull/42\n", 0}

          executable, args, opts ->
            runner(executable, args, opts)
        end

        assert {:error,
                %PhasePR.Error{
                  reason: :pr_lookup_failed,
                  details: %{state: unquote(lookup), reason: {:timeout, 20}}
                }} = PhasePR.maybe_create(request(%{command_runner: slow, lookup_timeout_ms: 20}))

        refute_received :gh_pr_create
      end
    end

    # GitHub moves a PR's head asynchronously after a push. The lookups of these tests: the
    # first is the one made before any effect, the rest follow the push.
    defp head_lagging_runner(heads) do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fn
        "gh", ["pr", "list", "--state", "open" | _], _opts ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          send(test, :gh_open_lookup)
          head = Enum.at(heads, n, List.last(heads))
          answer([pr_item(%{"headRefOid" => head})])

        "gh", ["pr", "list", "--state", "closed" | _], _opts ->
          {"[]", 0}

        "gh", ["pr", "create" | _], _opts ->
          send(test, :gh_pr_create)
          {"https://github.com/acme/repo/pull/42\n", 0}

        executable, args, opts ->
          runner(executable, args, opts)
      end
    end

    defp open_lookups(acc \\ 0) do
      receive do
        :gh_open_lookup -> open_lookups(acc + 1)
      after
        0 -> acc
      end
    end

    test "an open PR whose head lags behind the push is looked up again and reused once its head is the tip" do
      runner = head_lagging_runner([@other_sha, @other_sha, @sha])

      assert {:ok,
              %PhasePR.Record{status: "existing", pr_url: "https://github.com/acme/repo/pull/7"}} =
               PhasePR.maybe_create(request(%{command_runner: runner}))

      # Before the effects, after the push (stale), after the push again (the tip).
      assert open_lookups() == 3
      refute_received :gh_pr_create
    end

    test "an open PR whose head stays behind through every try is the :pr_lookup_mismatch, after three tries past the push" do
      runner = head_lagging_runner([@other_sha])

      assert {:error,
              %PhasePR.Error{
                reason: :pr_lookup_mismatch,
                details: %{
                  url: "https://github.com/acme/repo/pull/7",
                  expected_head: @sha,
                  actual_head: @other_sha
                }
              }} = PhasePR.maybe_create(request(%{command_runner: runner}))

      assert open_lookups() == 4
      refute_received :gh_pr_create
    end

    test "the sleep between the tries is the request's" do
      runner = head_lagging_runner([@other_sha])
      started = System.monotonic_time(:millisecond)

      assert {:error, %PhasePR.Error{reason: :pr_lookup_mismatch}} =
               PhasePR.maybe_create(request(%{command_runner: runner, lookup_retry_sleep_ms: 60}))

      # Two sleeps between three tries after the push.
      assert System.monotonic_time(:millisecond) - started >= 120
    end
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

      "gh", ["pr", "list", "--state", "open" | _], opts ->
        if Agent.get(gh_state, & &1.open?) do
          # GitHub's PR follows the branch on the remote: its head is the pushed tip.
          {line, 0} =
            System.cmd("git", ["ls-remote", "origin", "refs/heads/foreman/run-1"], cd: opts[:cd])

          [tip | _] = String.split(line)
          {Jason.encode!([pr_item(%{"headRefOid" => tip})]), 0}
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

  # A `gh pr list` item as `PrLookup` asks for it: this repository's open PR for the tip.
  defp pr_item(attrs \\ %{}) do
    Map.merge(
      %{
        "url" => "https://github.com/acme/repo/pull/7",
        "number" => 7,
        "state" => "OPEN",
        "headRefOid" => @sha,
        "isCrossRepository" => false
      },
      attrs
    )
  end

  defp answer(items), do: {Jason.encode!(items), 0}

  # The runner of `runner/3` with `gh pr list` answers scripted per state (`open: reply`,
  # `closed: reply`, default `[]`). It tells the test every `gh pr list` and `gh pr create`.
  defp scripted_runner(replies) do
    test = self()

    fn
      "gh", ["pr", "list", "--state", state | _] = args, opts ->
        send(test, {:gh_pr_list, state, args, opts})
        Keyword.get(replies, String.to_existing_atom(state), {"[]", 0})

      "gh", ["pr", "create" | _] = args, opts ->
        send(test, {:gh_pr_create, args})
        runner("gh", args, opts)

      executable, args, opts ->
        runner(executable, args, opts)
    end
  end
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

  import ExUnit.CaptureLog

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
      lookup_retry_sleep_ms: 0,
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

  # The status an undecided key has: `started` as the dead process left it, or `ambiguous`
  # as the boot sweep marks it before it has decided it.
  defp undecided!(key, :started), do: :ok = KeyStore.mark_started(key, %{})
  defp undecided!(key, :ambiguous), do: :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")

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

  describe "a key nobody has decided" do
    for status <- [:started, :ambiguous] do
      test "a #{status} push key is refused with a typed error naming the key: nothing runs",
           %{request: request, world: world, push_key: push_key} do
        EffectWorld.crash!(world, :push, :before, fn -> PhasePR.maybe_create(request) end)
        undecided!(push_key, unquote(status))
        {:ok, before_key} = KeyStore.get(push_key)

        log =
          capture_log(fn ->
            assert {:error,
                    %PhasePR.Error{
                      reason: :effect_undecided,
                      details: %{effect: :branch_push, key: ^push_key}
                    }} = PhasePR.maybe_create(request)
          end)

        assert log =~ "branch_push NOT run"
        assert log =~ push_key
        assert EffectWorld.executed(world, :push) == 0
        assert EffectWorld.executed(world, :create) == 0
        assert {:ok, ^before_key} = KeyStore.get(push_key)
      end

      test "a #{status} PR-create key is refused before the push: the push is not repeated either",
           %{request: request, world: world, create_key: create_key} do
        # The push goes through once; the create then dies before it reaches GitHub.
        EffectWorld.crash!(world, :create, :before, fn -> PhasePR.maybe_create(request) end)
        assert EffectWorld.executed(world, :push) == 1
        undecided!(create_key, unquote(status))
        {:ok, before_key} = KeyStore.get(create_key)

        log =
          capture_log(fn ->
            assert {:error,
                    %PhasePR.Error{
                      reason: :effect_undecided,
                      details: %{effect: :pr_create, key: ^create_key}
                    }} = PhasePR.maybe_create(request)
          end)

        assert log =~ "pr_create NOT run"
        assert log =~ create_key
        assert EffectWorld.executed(world, :push) == 1
        assert EffectWorld.executed(world, :create) == 0
        assert EffectWorld.prs(world) == []
        assert {:ok, ^before_key} = KeyStore.get(create_key)
      end
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
      # The sweep blocks the run before `PhasePR` can resume it; what `PhasePR` itself does
      # with a merged PR is the next test.
      EffectWorld.crash!(world, :create, :after, fn -> PhasePR.maybe_create(request) end)
      EffectWorld.merge_prs!(world)

      EffectWorld.sweep(world)
      resume_unless_blocked(run_id, request)

      assert EffectWorld.executed(world, :create) == 1
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
    end

    test "a merged PR of the branch on GitHub refuses creation: the closed lookup lists it, no second PR is created",
         %{request: request, world: world, fx: fx} do
      url = EffectWorld.add_pr!(world, fx.head, fx.base, "MERGED")

      :ok =
        EffectWorld.report_pr!(world, url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      assert {:error,
              %PhasePR.Error{
                reason: :matching_pr_closed,
                details: %ForemanServer.GitHub.PrLookup.Pr{url: ^url, state: :merged}
              }} = PhasePR.maybe_create(request)

      assert EffectWorld.executed(world, :create) == 0
      assert length(EffectWorld.prs(world)) == 1
    end

    for status <- [:started, :ambiguous] do
      test "an open PR with the tip is reused though the PR-create key is #{status} and unresolved: the key settles, nothing is pushed or created",
           %{request: request, world: world, fx: fx, create_key: create_key} do
        undecided!(create_key, unquote(status))
        :ok = KeyStore.mark_unresolved(create_key, 3, "effect_already_done")
        url = EffectWorld.add_pr!(world, fx.head, fx.base)

        :ok =
          EffectWorld.report_pr!(world, url,
            head_sha: EffectWorld.local_tip(fx),
            cross_repository: false
          )

        assert {:ok, %PhasePR.Record{status: "existing", pr_url: ^url}} =
                 PhasePR.maybe_create(request)

        assert {:ok, %{status: :completed, metadata: settled}} = KeyStore.get(create_key)
        assert KeyStore.unresolved_version(settled) == :none
        assert KeyStore.decision(settled) == :none
        assert EffectWorld.executed(world, :push) == 0
        assert EffectWorld.executed(world, :create) == 0
      end
    end

    test "a gh pr create that fails after GitHub got the PR is looked up once more: the PR with the tip is adopted and the key completes",
         %{request: request, world: world, fx: fx, create_key: create_key} do
      world_runner = EffectWorld.runner(world)

      racing = fn
        "gh", ["pr", "create" | _], _opts ->
          # A concurrent caller opened the PR between our lookups; gh refuses the duplicate.
          url = EffectWorld.add_pr!(world, fx.head, fx.base)

          :ok =
            EffectWorld.report_pr!(world, url,
              head_sha: EffectWorld.local_tip(fx),
              cross_repository: false
            )

          {"a pull request for branch already exists\n", 1}

        executable, args, opts ->
          world_runner.(executable, args, opts)
      end

      assert {:ok, %PhasePR.Record{status: "existing", pr_url: url}} =
               PhasePR.maybe_create(%{request | command_runner: racing})

      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert {:ok, :completed} = KeyStore.status(create_key)
    end

    test "a gh pr create that fails with no PR on GitHub keeps its own typed error and the key failed",
         %{request: request, world: world, create_key: create_key} do
      world_runner = EffectWorld.runner(world)

      refused = fn
        "gh", ["pr", "create" | _], _opts -> {"GraphQL: boom\n", 1}
        executable, args, opts -> world_runner.(executable, args, opts)
      end

      assert {:error, %PhasePR.Error{reason: :gh_pr_create_failed}} =
               PhasePR.maybe_create(%{request | command_runner: refused})

      assert EffectWorld.prs(world) == []
      assert {:ok, :failed} = KeyStore.status(create_key)
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
