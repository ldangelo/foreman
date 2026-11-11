defmodule ForemanServer.Idempotency.Reconcilers.PrCreateTest do
  @moduledoc """
  `Reconcilers.PrCreate` (TRD-013): GitHub is the source of truth for whether the PR
  exists. The query is `gh pr list --head <head> --base <base> --state all --json
  url,number,state` in the key's `cwd`; a PR in any state is `:done`, none is
  `:not_done`, and an answer that cannot be read is `:unknown`. The boot sweep reaches
  it through the configured registry, here with a fake `gh` first on `PATH`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.{Effect, KeyStore, Reconciler}
  alias ForemanServer.Idempotency.Reconcilers.PrCreate
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.Workflow.BootReconciliation

  @project_id "project-pr-create-reconciler"
  @head "foreman/run-1/implement"
  @base "main"

  setup_all do
    path = Path.join(System.tmp_dir!(), "pr-create-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    :ok = EffectWorld.register_project!(@project_id, path)
  end

  setup do
    KeyStoreReset.reset!()
    on_exit(&KeyStoreReset.reset!/0)

    cwd = Path.join(System.tmp_dir!(), "pr-create-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    {:ok, cwd: cwd}
  end

  # The metadata `Effect.run/4` stores for a PR create, as it reads back after a restart.
  defp metadata(cwd, extra \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-1",
        "effect_class" => "pr_create",
        "head_branch" => @head,
        "base_branch" => @base,
        "cwd" => cwd
      },
      extra
    )
  end

  describe "key/3 and intent/4" do
    test "the key is stable across attempts and tells PRs apart by run, head and base" do
      key = PrCreate.key("run-1", @head, @base)

      assert key == PrCreate.key("run-1", @head, @base)
      assert key == "effect:pr_create:run-1:#{@head}:#{@base}"
      refute key == PrCreate.key("run-2", @head, @base)
      refute key == PrCreate.key("run-1", "foreman/run-1/other", @base)
      refute key == PrCreate.key("run-1", @head, "develop")
    end

    test "the intent carries the run, both branches and the cwd" do
      assert PrCreate.intent("run-1", @head, @base, "/work/tree") == %{
               run_id: "run-1",
               head_branch: @head,
               base_branch: @base,
               cwd: "/work/tree"
             }
    end
  end

  describe "reconcile/2 against a scripted GitHub" do
    test "asks `gh pr list` for the head and base in any state, in the key's cwd", %{cwd: cwd} do
      world = EffectWorld.start()

      assert PrCreate.reconcile(metadata(cwd), command_runner: EffectWorld.runner(world)) ==
               :not_done

      assert [{"gh", args, opts}] = EffectWorld.calls(world)

      assert args == [
               "pr",
               "list",
               "--head",
               @head,
               "--base",
               @base,
               "--state",
               "all",
               "--json",
               "url,number,state"
             ]

      assert opts[:cd] == cwd
      refute opts[:cd] == File.cwd!()
    end

    for state <- ["OPEN", "CLOSED", "MERGED"] do
      test "a #{state} PR for the head and base is :done", %{cwd: cwd} do
        world = EffectWorld.start()
        EffectWorld.add_pr!(world, @head, @base, unquote(state))

        assert PrCreate.reconcile(metadata(cwd), command_runner: EffectWorld.runner(world)) ==
                 :done
      end
    end

    test "a PR merged or closed before recovery ran is found only because the query says --state all",
         %{cwd: cwd} do
      # `gh pr list` without `--state all` lists open PRs only: the scripted GitHub answers a
      # merged or closed PR to the `--state all` query alone.
      world = EffectWorld.start()
      EffectWorld.add_pr!(world, @head, @base, "MERGED")
      runner = EffectWorld.runner(world)

      assert {"[]", 0} = runner.("gh", ["pr", "list", "--head", @head, "--base", @base], [])

      assert PrCreate.reconcile(metadata(cwd), command_runner: runner) == :done
    end

    test "no PR for the head and base is :not_done, whatever other PRs exist", %{cwd: cwd} do
      world = EffectWorld.start()
      EffectWorld.add_pr!(world, "foreman/run-1/other", @base)
      EffectWorld.add_pr!(world, @head, "develop")

      assert PrCreate.reconcile(metadata(cwd), command_runner: EffectWorld.runner(world)) ==
               :not_done
    end

    test "a GitHub that cannot be queried is :unknown, never :not_done", %{cwd: cwd} do
      world = EffectWorld.start()
      EffectWorld.fail_gh_list!(world)

      assert PrCreate.reconcile(metadata(cwd), command_runner: EffectWorld.runner(world)) ==
               :unknown
    end

    test "an answer that is not a PR list is :unknown", %{cwd: cwd} do
      for answer <- [
            "not json",
            "{\"message\":\"Bad credentials\"}",
            "[{\"state\":\"OPEN\"}]",
            "[1]"
          ] do
        runner = fn "gh", _args, _opts -> {answer, 0} end

        assert PrCreate.reconcile(metadata(cwd), command_runner: runner) == :unknown
      end
    end

    test "a runner that cannot start gh in the cwd is :unknown", %{cwd: cwd} do
      gone = cwd <> "-gone"

      assert PrCreate.reconcile(metadata(cwd, %{"cwd" => gone})) == :unknown
    end

    test "metadata that lacks the head, base or cwd is :unknown and runs nothing", %{cwd: cwd} do
      test = self()

      runner = fn executable, args, opts ->
        send(test, {:ran, executable, args, opts})
        {"[]", 0}
      end

      for field <- ["head_branch", "base_branch", "cwd"], value <- [nil, ""] do
        assert PrCreate.reconcile(metadata(cwd, %{field => value}), command_runner: runner) ==
                 :unknown
      end

      refute_received {:ran, _, _, _}
    end
  end

  describe "reconcile/2 never waits on gh for ever" do
    # The boot sweep runs the reconcilers inside BootReconciliation, so a hung `gh pr list`
    # would stop every later boot scan. `@tag timeout` fails the test instead of hanging it.
    @tag timeout: 5_000
    test "a gh that does not answer within timeout_ms is :unknown, and the call returns promptly",
         %{cwd: cwd} do
      test = self()

      runner = fn _executable, _args, _opts ->
        send(test, {:runner, self()})
        Process.sleep(:infinity)
      end

      {elapsed_us, verdict} =
        :timer.tc(fn ->
          PrCreate.reconcile(metadata(cwd), command_runner: runner, timeout_ms: 50)
        end)

      assert verdict == :unknown
      assert elapsed_us < 3_000_000
      assert_received {:runner, runner_pid}
      refute Process.alive?(runner_pid)
    end
  end

  describe "the boot sweep reaches it through the configured registry" do
    setup %{cwd: cwd} do
      bin = Path.join(cwd, "bin")
      File.mkdir_p!(bin)
      answers = Path.join(cwd, "answers")
      File.mkdir_p!(answers)
      log = Path.join(cwd, "gh.log")
      File.write!(Path.join(answers, "prs.json"), "[]")
      File.write!(Path.join(bin, "gh"), fake_gh(answers, log))
      File.chmod!(Path.join(bin, "gh"), 0o755)

      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      on_exit(fn -> System.put_env("PATH", path) end)

      run_id = EffectWorld.start_run!(@project_id, "pr-create-sweep")

      {:ok, run_id: run_id, key: PrCreate.key(run_id, @head, @base), answers: answers, log: log}
    end

    # `--state all` is the only query the fake answers with the PRs; any other lists none, as
    # `gh pr list` lists only open PRs. `pwd -P` is the directory the process was started in.
    defp fake_gh(answers, log) do
      """
      #!/bin/sh
      echo "$(pwd -P)|$*" >> "#{log}"
      if [ -e "#{answers}/fail" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
      case "$*" in
        *"--state all"*) cat "#{answers}/prs.json" ;;
        *) echo "[]" ;;
      esac
      """
    end

    # What a crash in the middle of `gh pr create` leaves: a `started` key with the intent.
    defp crash_in_create(run_id, cwd) do
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Effect.run(
            :pr_create,
            PrCreate.key(run_id, @head, @base),
            fn ->
              send(test, :in_effect)
              Process.sleep(:infinity)
            end,
            PrCreate.intent(run_id, @head, @base, cwd)
          )
        end)

      assert_receive :in_effect
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    defp sweep, do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

    test "the registry maps the class to this module" do
      assert Reconciler.classes()["pr_create"] == PrCreate
    end

    test "a PR that was merged before recovery ran blocks the run and nothing is created",
         %{cwd: cwd, run_id: run_id, key: key, answers: answers, log: log} do
      File.write!(
        Path.join(answers, "prs.json"),
        ~s([{"number":7,"state":"MERGED","url":"https://github.com/acme/widgets/pull/7"}])
      )

      crash_in_create(run_id, cwd)
      assert {:ok, :started} = KeyStore.status(key)

      sweep()

      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_already_done"
      assert {:ok, :ambiguous} = KeyStore.status(key)

      {expected_cwd, 0} = System.cmd("pwd", ["-P"], cd: cwd)
      assert [line] = File.read!(log) |> String.split("\n", trim: true)

      assert line ==
               "#{String.trim(expected_cwd)}|pr list --head #{@head} --base #{@base} --state all --json url,number,state"
    end

    test "no PR means the create is retried: recorded, nothing blocked, key left for the next attempt",
         %{cwd: cwd, run_id: run_id, key: key} do
      crash_in_create(run_id, cwd)

      sweep()

      assert EffectWorld.status(run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(run_id) == ["effect_retried"]
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a GitHub that cannot be queried blocks the run as ambiguous",
         %{cwd: cwd, run_id: run_id, key: key, answers: answers} do
      File.write!(Path.join(answers, "fail"), "")
      crash_in_create(run_id, cwd)

      sweep()

      assert EffectWorld.status(run_id) == "blocked"
      assert EffectWorld.block_reason(run_id) == "effect_outcome_ambiguous"
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end
  end
end
