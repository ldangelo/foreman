defmodule ForemanServer.Idempotency.Reconcilers.BranchPushTest do
  @moduledoc """
  `Reconcilers.BranchPush` (TRD-013) against a real git repository with a bare
  repository as `origin`: the intent it records before a push, the three-way
  comparison of the remote head it applies after a crash (landed, not landed,
  unknown) and the equal-SHA case, ending with the boot sweep reaching it through the
  configured registry after a crash in the middle of `AutoPR`'s push.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.Idempotency.Reconcilers.BranchPush
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.Workflow.{AutoPR, BootReconciliation}

  @project_id "project-branch-push-reconciler"

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "branch-push-project-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    :ok = EffectWorld.register_project!(@project_id, path)
  end

  setup do
    KeyStoreReset.reset!()
    on_exit(&KeyStoreReset.reset!/0)
    :ok
  end

  # The metadata `Effect.run/4` stores for a push, as it reads back after a restart.
  defp metadata(fx, pre, pushed, extra \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-branch-push",
        "effect_class" => "branch_push",
        "head_branch" => fx.head,
        "cwd" => fx.repo,
        "pre_push_remote_sha" => pre,
        "pushed_local_sha" => pushed
      },
      extra
    )
  end

  # Real `git`, with every command reported to the test.
  defp recording_runner do
    test = self()

    fn executable, args, opts ->
      send(test, {:ran, executable, args, opts})
      System.cmd(executable, args, opts)
    end
  end

  defp commit_locally!(fx, name), do: EffectWorld.commit_on_head!(fx, name)

  describe "intent/4" do
    test "records no remote head for a branch the remote does not have, and the local tip" do
      fx = EffectWorld.fixture!("feature/new")

      assert {:ok, meta} = BranchPush.intent(&System.cmd/3, "run-1", fx.head, fx.repo)

      assert meta == %{
               run_id: "run-1",
               head_branch: fx.head,
               cwd: fx.repo,
               pre_push_remote_sha: nil,
               pushed_local_sha: EffectWorld.local_tip(fx)
             }
    end

    test "records the remote head as it stands when the remote already has the branch" do
      fx = EffectWorld.fixture!("feature/existing")
      EffectWorld.publish!(fx)
      old_tip = EffectWorld.local_tip(fx)
      new_tip = commit_locally!(fx, "more.txt")
      refute new_tip == old_tip

      assert {:ok, meta} = BranchPush.intent(&System.cmd/3, "run-1", fx.head, fx.repo)
      assert meta.pre_push_remote_sha == old_tip
      assert meta.pushed_local_sha == new_tip
    end

    test "reads both heads in the push's cwd with the commands the reconciler compares against" do
      fx = EffectWorld.fixture!("feature/cmds")

      assert {:ok, _} = BranchPush.intent(recording_runner(), "run-1", fx.head, fx.repo)

      assert_received {:ran, "git", ["ls-remote", "origin", remote_ref], remote_opts}
      assert remote_ref == "refs/heads/" <> fx.head
      assert remote_opts[:cd] == fx.repo

      assert_received {:ran, "git", ["rev-parse", "--verify", local_ref], local_opts}
      assert local_ref == "refs/heads/" <> fx.head
      assert local_opts[:cd] == fx.repo
    end

    test "an unreadable remote head means no intent" do
      fx = EffectWorld.fixture!("feature/unreadable")
      EffectWorld.break_origin!(fx)

      assert {:error, {:intent_not_recorded, {:remote_head_unreadable, {code, _output}}}} =
               BranchPush.intent(&System.cmd/3, "run-1", fx.head, fx.repo)

      assert code != 0
    end

    test "a local branch that does not exist means no intent, and the remote is not asked" do
      fx = EffectWorld.fixture!("feature/real")

      assert {:error, {:intent_not_recorded, {:local_head_unreadable, _}}} =
               BranchPush.intent(recording_runner(), "run-1", "feature/missing", fx.repo)

      refute_received {:ran, "git", ["ls-remote" | _], _}
    end

    test "no cwd means no intent and no command runs, not even in the server's directory" do
      for cwd <- [nil, ""] do
        assert {:error, {:intent_not_recorded, :cwd_missing}} =
                 BranchPush.intent(recording_runner(), "run-1", "feature/x", cwd)
      end

      refute_received {:ran, _, _, _}
    end
  end

  describe "reconcile/2 against a real repository and a bare origin" do
    test "the remote ref equals the pushed SHA: the push landed (:done)" do
      fx = EffectWorld.fixture!("feature/landed")
      pushed = EffectWorld.local_tip(fx)
      EffectWorld.publish!(fx)

      assert BranchPush.reconcile(metadata(fx, nil, pushed)) == :done
    end

    test "the remote ref equals the pushed SHA on a branch the remote already had (:done)" do
      fx = EffectWorld.fixture!("feature/landed-update")
      EffectWorld.publish!(fx)
      pre = EffectWorld.local_tip(fx)
      pushed = commit_locally!(fx, "update.txt")
      EffectWorld.publish!(fx)

      assert BranchPush.reconcile(metadata(fx, pre, pushed)) == :done
    end

    test "the remote ref is still the pre-push SHA: the push did not land (:not_done)" do
      fx = EffectWorld.fixture!("feature/not-landed-update")
      EffectWorld.publish!(fx)
      pre = EffectWorld.local_tip(fx)
      pushed = commit_locally!(fx, "update.txt")

      assert EffectWorld.remote_tip(fx) == pre
      assert BranchPush.reconcile(metadata(fx, pre, pushed)) == :not_done
    end

    test "a branch the remote did not have and still does not is :not_done (both absent are equal)" do
      fx = EffectWorld.fixture!("feature/not-landed-new")

      assert EffectWorld.remote_tip(fx) == nil
      assert BranchPush.reconcile(metadata(fx, nil, EffectWorld.local_tip(fx))) == :not_done
    end

    test "another commit landed instead: the remote ref equals neither SHA (:unknown)" do
      fx = EffectWorld.fixture!("feature/other-new")
      pushed = EffectWorld.local_tip(fx)
      other = EffectWorld.land_other_commit!(fx)

      refute other == pushed
      assert EffectWorld.remote_tip(fx) == other
      assert BranchPush.reconcile(metadata(fx, nil, pushed)) == :unknown
    end

    test "another commit landed on top of the pre-push head (:unknown)" do
      fx = EffectWorld.fixture!("feature/other-update")
      EffectWorld.publish!(fx)
      pre = EffectWorld.local_tip(fx)
      pushed = commit_locally!(fx, "update.txt")
      other = EffectWorld.land_other_commit!(fx)

      refute other in [pre, pushed]
      assert BranchPush.reconcile(metadata(fx, pre, pushed)) == :unknown
    end

    test "the branch the push was meant to update is gone from the remote (:unknown)" do
      fx = EffectWorld.fixture!("feature/deleted")
      EffectWorld.publish!(fx)
      pre = EffectWorld.local_tip(fx)
      pushed = commit_locally!(fx, "update.txt")
      EffectWorld.git!(fx.repo, ["push", "origin", "--delete", fx.head])

      assert EffectWorld.remote_tip(fx) == nil
      assert BranchPush.reconcile(metadata(fx, pre, pushed)) == :unknown
    end

    test "a remote ref that cannot be read is :unknown, never :not_done" do
      fx = EffectWorld.fixture!("feature/unreachable")
      pushed = EffectWorld.local_tip(fx)
      EffectWorld.break_origin!(fx)

      assert BranchPush.reconcile(metadata(fx, nil, pushed)) == :unknown
    end

    test "a cwd that is not a directory is :unknown" do
      fx = EffectWorld.fixture!("feature/no-cwd")
      pushed = EffectWorld.local_tip(fx)
      gone = fx.repo <> "-gone"

      assert BranchPush.reconcile(metadata(fx, nil, pushed, %{"cwd" => gone})) == :unknown
    end

    test "metadata that lacks a field the comparison needs is :unknown and runs nothing" do
      fx = EffectWorld.fixture!("feature/incomplete")
      pushed = EffectWorld.local_tip(fx)

      for field <- ["head_branch", "cwd", "pushed_local_sha"], value <- [nil, ""] do
        meta = metadata(fx, nil, pushed, %{field => value})

        assert BranchPush.reconcile(meta, command_runner: recording_runner()) == :unknown
      end

      refute_received {:ran, _, _, _}
    end

    test "SHAs compare case-insensitively" do
      fx = EffectWorld.fixture!("feature/case")
      pushed = EffectWorld.local_tip(fx)
      EffectWorld.publish!(fx)

      assert BranchPush.reconcile(metadata(fx, nil, String.upcase(pushed))) == :done
    end
  end

  describe "reconcile/2 when origin already held the tip before the push (equal SHAs)" do
    setup do
      fx = EffectWorld.fixture!("feature/equal")
      EffectWorld.publish!(fx)
      tip = EffectWorld.local_tip(fx)
      {:ok, fx: fx, tip: tip, meta: metadata(fx, tip, tip)}
    end

    test "is :not_done while the remote still holds it", %{meta: meta} do
      assert BranchPush.reconcile(meta) == :not_done
    end

    test "is :not_done whatever the remote ref is now: moved on", %{fx: fx, meta: meta} do
      EffectWorld.land_other_commit!(fx)

      assert BranchPush.reconcile(meta) == :not_done
    end

    test "is :not_done whatever the remote ref is now: unreadable", %{fx: fx, meta: meta} do
      EffectWorld.break_origin!(fx)

      assert BranchPush.reconcile(meta) == :not_done
    end

    test "does not even read the remote", %{meta: meta} do
      assert BranchPush.reconcile(meta, command_runner: recording_runner()) == :not_done

      refute_received {:ran, _, _, _}
    end
  end

  describe "reconcile/2 runs git in the key's cwd" do
    test "the remote ref is read with `cd:` the key's cwd, not the server's directory" do
      test = self()

      # The remote has no such branch whatever the directory: only the options say where it ran.
      runner = fn executable, args, opts ->
        send(test, {:ran, executable, args, opts})
        {"", 0}
      end

      meta = %{
        "run_id" => "run-branch-push",
        "head_branch" => "feature/cwd",
        "cwd" => "/work/tree",
        "pre_push_remote_sha" => nil,
        "pushed_local_sha" => "0123456789abcdef0123456789abcdef01234567"
      }

      assert BranchPush.reconcile(meta, command_runner: runner) == :not_done

      assert_received {:ran, "git", ["ls-remote", "origin", "refs/heads/feature/cwd"], opts}
      assert opts[:cd] == "/work/tree"
      refute opts[:cd] == File.cwd!()
    end
  end

  describe "the boot sweep reaches it through the configured registry" do
    setup do
      run_id = EffectWorld.start_run!(@project_id, "push-sweep")
      fx = EffectWorld.fixture!("foreman/#{run_id}/implement")
      world = EffectWorld.start()

      ctx = %{
        run_id: run_id,
        base_branch: fx.base,
        head_branch: fx.head,
        cwd: fx.repo,
        command_runner: EffectWorld.runner(world)
      }

      {:ok, run_id: run_id, fx: fx, world: world, ctx: ctx, key: BranchPush.key(run_id, fx.head)}
    end

    # The sweep with no `classes:` override: `Reconciler.classes/0`, i.e. config.exs,
    # and `System.cmd/3` for the reconciler's own `git`.
    defp sweep, do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

    # What the run's executor does on resumption. A blocked run is cancelled by the
    # sweep and never gets here.
    defp resume_unless_blocked(run_id, fun),
      do: if(EffectWorld.status(run_id) != "blocked", do: fun.())

    test "the registry maps the class to this module" do
      assert Reconciler.classes()["branch_push"] == BranchPush
    end

    test "a crash after the push reached the remote blocks the run and no second push is issued",
         %{run_id: run_id, world: world, ctx: ctx, key: key} do
      EffectWorld.crash!(world, :push, :after, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :push) == 1

      sweep()
      resume_unless_blocked(run_id, fn -> AutoPR.maybe_create_pr(ctx) end)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a crash before the push reached the remote retries it, once",
         %{run_id: run_id, fx: fx, world: world, ctx: ctx, key: key} do
      EffectWorld.crash!(world, :push, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.remote_tip(fx) == nil

      sweep()

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]
      assert {:ok, :ambiguous} = KeyStore.status(key)

      resume_unless_blocked(run_id, fn -> assert {:ok, _url} = AutoPR.maybe_create_pr(ctx) end)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a remote ref that equals neither SHA blocks the run as ambiguous and nothing is pushed",
         %{run_id: run_id, fx: fx, world: world, ctx: ctx, key: key} do
      EffectWorld.crash!(world, :push, :before, fn -> AutoPR.maybe_create_pr(ctx) end)
      other = EffectWorld.land_other_commit!(fx)

      sweep()
      resume_unless_blocked(run_id, fn -> AutoPR.maybe_create_pr(ctx) end)

      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_outcome_ambiguous"
      assert EffectWorld.remote_tip(fx) == other
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "origin that already held the tip: the crashed push is retried, as a no-op, not blocked",
         %{run_id: run_id, fx: fx, world: world, ctx: ctx, key: key} do
      EffectWorld.publish!(fx)
      tip = EffectWorld.local_tip(fx)

      EffectWorld.crash!(world, :push, :after, fn -> AutoPR.maybe_create_pr(ctx) end)

      assert {:ok, %{metadata: %{"pre_push_remote_sha" => ^tip, "pushed_local_sha" => ^tip}}} =
               KeyStore.get(key)

      sweep()

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]

      resume_unless_blocked(run_id, fn -> assert {:ok, _url} = AutoPR.maybe_create_pr(ctx) end)

      assert EffectWorld.remote_tip(fx) == tip
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end
end
