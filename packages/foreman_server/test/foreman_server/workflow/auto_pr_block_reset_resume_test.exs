defmodule ForemanServer.Workflow.AutoPRBlockResetResumeTest do
  @moduledoc """
  The `foreman-tnlqt` wedge (limitation (xvii) of the Phase 0 decision record), walked instead of
  inferred from source. The decision record says the block, reset, resume sequence "was not walked
  before this record was written"; this test walks it, step by step, and asserts what each step
  leaves behind.

    1. The first attempt: `gh pr create` reaches GitHub, and the executor dies before the key
       settles. The key stays `started`.
    2. The boot sweep asks GitHub, reads `done`, marks the key unresolved and blocks the run.
    3. The operator resets the run (`run.reset`): the unresolved marker no longer refuses the key,
       so an attempt that does not look first would lift it and run `gh pr create` again.
    4. The run restarts.
    5. The resumed run reaches `AutoPR`, and GitHub, which refuses a second open PR for a head and
       base that already have one exactly as `gh pr create` reports it, would turn a repeated
       create away with "already exists": the key would settle `failed` and the run would fail
       again on every reset. `AutoPR` asks GitHub first and adopts the PR, with the key still as
       the sweep left it.

  Real: the run aggregate and its stream, the boot sweep with the real `pr_create` reconciler,
  `run.reset` through the command gateway, the key store, `AutoPR`, git with a bare origin.
  Scripted: GitHub (`EffectWorld`'s PRs).
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.{CommandGateway, CommandRouter, EventStore}
  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.{BranchPush, PrCreate}
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.Workflow.{AutoPR, RunExecutor}

  @project_id "project-autopr-block-reset-resume"

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "autopr-block-reset-resume-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    :ok = EffectWorld.register_project!(@project_id, path)
  end

  setup do
    KeyStoreReset.reset!()
    on_exit(&KeyStoreReset.reset!/0)

    run_id = EffectWorld.start_run!(@project_id, "autopr-reset")
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

  # GitHub as the resumed run meets it. A second open PR for a head and base that already have
  # one is refused as `gh pr create` reports it, and the test is told what the run asked and what
  # the key looked like when it asked GitHub.
  defp resumed_runner(world, fx, key) do
    test = self()
    world_runner = EffectWorld.runner(world)

    fn
      "gh", ["pr", "list" | _] = args, opts ->
        send(test, {:asked_github, KeyStore.get(key)})
        world_runner.("gh", args, opts)

      "gh", ["pr", "create" | _] = args, opts ->
        send(test, {:create_attempt, args})

        open =
          Enum.find(
            EffectWorld.prs(world),
            &(&1["state"] == "OPEN" and &1["head"] == fx.head and &1["base"] == fx.base)
          )

        case open do
          %{"url" => url} ->
            {"a pull request for branch \"#{fx.head}\" into branch \"#{fx.base}\" already exists:\n#{url}\n",
             1}

          nil ->
            world_runner.("gh", args, opts)
        end

      "git", ["push" | _] = args, opts ->
        send(test, {:push_attempt, args})
        world_runner.("git", args, opts)

      executable, args, opts ->
        world_runner.(executable, args, opts)
    end
  end

  defp event_types(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    Enum.map(recorded, & &1.event_type)
  end

  defp reset!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.reset",
        command_id: "reset-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{"run_id" => run_id}
      })

    :ok
  end

  # The start command id derives from the workflow snapshot, so a restart after a reset carries
  # another one: the same snapshot would be replayed, not started again.
  defp restart!(run_id) do
    {:ok, _} =
      CommandRouter.dispatch_run_start(@project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [], attempt: 2}
      })

    :ok
  end

  test "a run blocked on a done verdict, reset and resumed adopts the PR GitHub already has, before it touches the key",
       %{ctx: ctx, fx: fx, world: world, run_id: run_id, create_key: key} do
    # Step 1: `gh pr create` reaches GitHub and the executor dies before the key settles.
    EffectWorld.crash!(world, :create, :after, fn -> AutoPR.maybe_create_pr(ctx) end)

    assert {:ok, :started} = KeyStore.status(key)
    assert EffectWorld.executed(world, :create) == 1
    assert [%{"url" => url}] = EffectWorld.prs(world)
    # GitHub knows the head of the PR it made: the commit that was pushed.
    :ok =
      EffectWorld.report_pr!(world, url,
        head_sha: EffectWorld.local_tip(fx),
        cross_repository: false
      )

    # Step 2: the boot sweep asks GitHub, reads `done`, marks the key unresolved, blocks the run.
    EffectWorld.sweep(world)

    assert EffectWorld.status(run_id) == "blocked"
    assert EffectWorld.block_reason(run_id) == "effect_already_done"
    assert EffectWorld.recovery_outcomes(run_id) == ["effect_blocked"]
    assert {:ok, %{status: :ambiguous, metadata: marked}} = before_resume = KeyStore.get(key)
    assert {:ok, _version} = KeyStore.unresolved_version(marked)

    assert {:error, {:effect_unresolved, ^key}} =
             Effect.preflight(:pr_create, key, %{"run_id" => run_id})

    # Step 3: the operator resets the run. The marker no longer refuses the key, so an attempt
    # that did not look first would lift it and run `gh pr create` again (the wedge).
    reset!(run_id)

    assert EffectWorld.status(run_id) == nil
    assert :ok = Effect.preflight(:pr_create, key, %{"run_id" => run_id})
    # The reset left the key as the sweep wrote it.
    assert ^before_resume = KeyStore.get(key)

    # Step 4: the run restarts.
    restart!(run_id)

    assert EffectWorld.status(run_id) not in [nil, "blocked"]

    assert event_types(run_id) ==
             ["RunStarted", "RunRecoveryAttempted", "RunBlocked", "RunReset", "RunStarted"]

    # Step 5: the resumed run reaches AutoPR again.
    assert {:ok, ^url} =
             AutoPR.maybe_create_pr(%{ctx | command_runner: resumed_runner(world, fx, key)})

    # GitHub was asked first, and the key was still as the sweep left it when it was.
    assert_received {:asked_github, ^before_resume}
    # Nothing was pushed or created: GitHub would have refused the duplicate.
    refute_received {:create_attempt, _args}
    refute_received {:push_attempt, _args}
    assert EffectWorld.executed(world, :create) == 1
    assert EffectWorld.executed(world, :push) == 1
    assert [%{"url" => ^url}] = EffectWorld.prs(world)

    # The key is settled, with what recovery wrote on it, so the run is not wedged on it again.
    assert {:ok, %{status: :completed, metadata: settled}} = KeyStore.get(key)
    assert KeyStore.unresolved_version(settled) == :none
    assert KeyStore.decision(settled) == :none
    assert :ok = Effect.preflight(:pr_create, key, %{"run_id" => run_id})
  end

  # The run executor's finalisation (`RunExecutor.finalize_primary_pr/1`, through `auto_pr/1`) is
  # what resumes a run's PR on production paths. It hands `AutoPR` no runner, so `gh` is the
  # executable on PATH and the lookup goes through the default runner, `System.cmd/3`.
  describe "the run executor's finalisation" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "autopr-finalise-#{System.unique_integer([:positive])}")

      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "gh"), fake_gh(root))
      File.chmod!(Path.join(bin, "gh"), 0o755)

      previous_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> previous_path)

      on_exit(fn ->
        System.put_env("PATH", previous_path)
        File.rm_rf(root)
      end)

      %{gh_dir: root}
    end

    test "a resumed run whose PR GitHub already has finalises with that PR: nothing is pushed or created",
         %{fx: fx, run_id: run_id, gh_dir: gh_dir, push_key: push_key, create_key: create_key} do
      url = "https://github.com/acme/widgets/pull/5"

      listed = [
        %{
          "url" => url,
          "number" => 5,
          "state" => "OPEN",
          "headRefOid" => EffectWorld.local_tip(fx),
          "isCrossRepository" => false
        }
      ]

      File.write!(Path.join(gh_dir, "list.json"), Jason.encode!(listed))

      state = %{
        run_id: run_id,
        task: nil,
        source: nil,
        current_phase: nil,
        phase_specs: [],
        plan_context: %{"project_root" => fx.repo},
        last_worktree: %{branch: fx.head},
        run_base_branch: {:ok, fx.base}
      }

      assert {:ok, ^url} = RunExecutor.__maybe_auto_pr_for_test__(state)

      # gh was asked to list the PRs, in the checkout, and nothing else: no push, no create.
      assert ["pr list cwd=" <> checkout] = gh_calls(gh_dir)
      assert checkout == Path.basename(fx.repo)
      assert EffectWorld.remote_tip(fx) == nil
      assert :not_found = KeyStore.get(push_key)
      assert :not_found = KeyStore.get(create_key)
    end
  end

  # `gh` as an executable: it lists what the test staged and fails on anything else, so a push
  # or a create that the run should not make is both logged and turned away.
  defp fake_gh(dir) do
    """
    #!/bin/sh
    echo "$1 $2 cwd=$(basename "$(pwd)")" >> "#{dir}/calls.log"
    case "$1 $2" in
      "pr list") cat "#{dir}/list.json" ;;
      *) echo "unexpected gh call: $*" >&2; exit 1 ;;
    esac
    """
  end

  defp gh_calls(dir) do
    case File.read(Path.join(dir, "calls.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
