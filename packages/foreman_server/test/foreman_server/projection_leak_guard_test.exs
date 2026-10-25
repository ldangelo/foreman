defmodule ForemanServer.ProjectionLeakGuardTest do
  # The guard that fails the suite when a module leaves a hand-written run id behind in the
  # shared ProjectionStore (foreman-fhe9o). Its decisions are plain functions; the store-facing
  # tests pin the projection fields it reads, so a renamed field cannot turn it into a no-op.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionLeakGuard, as: Guard
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @live "run-leak-guard-live"
  @done "run-leak-guard-done"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp started(run_id) do
    payload = %{run_id: run_id, task_id: "t", project_id: "p", workflow_snapshot: %{}}
    %{event_type: "RunStarted", payload: payload}
  end

  # The ids typed in THIS file are the fixed ones here.
  defp fixed_ids, do: Guard.fixed_ids([File.read!(__ENV__.file)])

  defp guard_state do
    {:ok, state} = Guard.init(fixed_ids: fixed_ids())
    state
  end

  defp run(run_id, terminal?), do: %{run_id: run_id, terminal?: terminal?}

  defp finished_module(name, opts \\ []) do
    test = %ExUnit.Test{
      name: :"test it",
      module: name,
      state: Keyword.get(opts, :state),
      tags: %{async: Keyword.get(opts, :async, false)}
    }

    %ExUnit.TestModule{name: name, tests: [test]}
  end

  describe "fixed_ids/1" do
    test "collects quoted literals and never an interpolated or generated id" do
      source = ~S"""
      run_id: "run-1", other: "run-other", spaced: "not an id"
      generated: "run-#{System.unique_integer([:positive])}"
      """

      ids = Guard.fixed_ids([source])

      assert "run-1" in ids
      assert "run-other" in ids
      refute "not an id" in ids
      refute Enum.any?(ids, &String.contains?(&1, "unique_integer"))
    end

    test "sees the literals of this very file" do
      ids = fixed_ids()

      assert @live in ids
      assert @done in ids
    end
  end

  describe "fixed_live_run_ids/2" do
    test "only non-terminal runs whose id is a typed literal" do
      runs = [run("run-1", false), run("run-2", true), run("run-3-generated", false)]

      assert Guard.fixed_live_run_ids(runs, MapSet.new(["run-1", "run-2"])) == ["run-1"]
    end

    test "reads the real projection: live, terminal, generated and wiped" do
      generated = "run-leak-guard-#{System.unique_integer([:positive])}"

      :ok =
        ProjectionStore.apply_events([
          started(@done),
          %{event_type: "RunCompleted", payload: %{run_id: @done, project_id: "p", sequence: 1}},
          started(generated)
        ])

      assert Guard.fixed_live_run_ids(ProjectionStore.list_runs(), fixed_ids()) == []

      :ok = ProjectionStore.apply_events([started(@live)])
      assert Guard.fixed_live_run_ids(ProjectionStore.list_runs(), fixed_ids()) == [@live]

      ProjectionStoreReset.reset!()
      assert Guard.fixed_live_run_ids(ProjectionStore.list_runs(), fixed_ids()) == []
    end
  end

  describe "judge/4" do
    test "blames the module a typed non-terminal run was left by" do
      runs = fn -> [run(@live, false), run(@done, true)] end

      state = Guard.judge(guard_state(), finished_module(ModLeaky), runs, fn -> 0 end)

      assert %{leaks: [%{run_id: @live, module: "ModLeaky"}], judged: 1, sync: 1} = state
    end

    test "a module that ended with a clean store is judged and not blamed" do
      state = Guard.judge(guard_state(), finished_module(ModClean), fn -> [] end, fn -> 0 end)

      assert %{leaks: [], judged: 1, sync: 1} = state
    end

    test "a read the runner may have overlapped is not judged, so it can blame nobody" do
      runs = fn -> [run(@live, false)] end

      for queued <- [1, 3] do
        state = Guard.judge(guard_state(), finished_module(ModBusy), runs, fn -> queued end)
        assert %{leaks: [], judged: 0, sync: 1} = state
      end
    end

    test "the mailbox is read after the store is, not before" do
      test_pid = self()

      runs = fn ->
        send(test_pid, :store_read)
        [run(@live, false)]
      end

      backlog = fn ->
        assert_received :store_read
        0
      end

      assert %{judged: 1} = Guard.judge(guard_state(), finished_module(ModOrder), runs, backlog)
    end

    test "async modules and modules that ran nothing are not judged" do
      runs = fn -> [run(@live, false)] end
      backlog = fn -> 0 end

      async = Guard.judge(guard_state(), finished_module(ModAsync, async: true), runs, backlog)
      assert %{leaks: [], judged: 0, sync: 0} = async

      skipped =
        Guard.judge(
          guard_state(),
          finished_module(ModSkipped, state: {:excluded, "tag"}),
          runs,
          backlog
        )

      assert %{leaks: [], judged: 0, sync: 0} = skipped
    end

    test "a module whose tests failed is still judged" do
      state =
        Guard.judge(
          guard_state(),
          finished_module(ModFailed, state: {:failed, []}),
          fn -> [run(@live, false)] end,
          fn -> 0 end
        )

      assert %{leaks: [%{module: "ModFailed"}], judged: 1} = state
    end

    test "judges what the real projection holds" do
      :ok = ProjectionStore.apply_events([started(@live)])

      state =
        Guard.judge(
          guard_state(),
          finished_module(ModLeaky),
          &ProjectionStore.list_runs/0,
          fn -> 0 end
        )

      assert %{leaks: [%{run_id: @live, module: "ModLeaky"}]} = state
    end
  end

  describe "verdict!/1" do
    test "passes when modules were judged and nothing was left behind, and says how many" do
      output =
        capture_io(fn -> assert Guard.verdict!(%{leaks: [], judged: 7, sync: 10}) == :ok end)

      assert output =~ "judged 7 of 10 modules, no run left behind"
    end

    test "passes a tiny run in which every boundary was skipped" do
      output =
        capture_io(fn -> assert Guard.verdict!(%{leaks: [], judged: 0, sync: 3}) == :ok end)

      assert output =~ "judged 0 of 3 modules"
    end

    test "fails, naming the run, the module and the file that types its id" do
      leaks = [
        %{run_id: "run-guard-demo", module: "ModA"},
        %{run_id: "run-guard-demo", module: "ModB"}
      ]

      error =
        assert_raise Mix.Error, fn ->
          Guard.verdict!(%{leaks: leaks, judged: 4, sync: 4})
        end

      assert error.message =~
               "\"run-guard-demo\": still in the store after ModA (and after 1 later"

      assert error.message =~ "unique_run_id"
      assert error.message =~ "ProjectionStoreReset"
      # the run id is typed in the test sources, e.g. the guard's own tests
      assert error.message =~ "projection_leak_guard_test.exs"
    end

    test "fails when the formatter never saw the end of the suite" do
      assert_raise Mix.Error, ~r/never saw the end of the suite/, fn -> Guard.verdict!(nil) end
    end

    test "fails when a whole suite was never judged: the guard is inert, not clean" do
      assert_raise Mix.Error, ~r/judged none of 10 modules/, fn ->
        Guard.verdict!(%{leaks: [], judged: 0, sync: 10})
      end
    end
  end

  describe "message/2 and typed_in/2" do
    test "one line per run, the first module it was seen after, and where it is typed" do
      message =
        Guard.message(
          [
            %{run_id: "run-2", module: "ModC"},
            %{run_id: "run-1", module: "ModA"},
            %{run_id: "run-1", module: "ModB"},
            %{run_id: "run-1", module: "ModB"}
          ],
          fn
            "run-1" -> ["test/a_test.exs", "test/b_test.exs"]
            "run-2" -> []
          end
        )

      assert message =~
               "\"run-1\": still in the store after ModA (and after 1 later module(s)); " <>
                 "typed in test/a_test.exs, test/b_test.exs"

      assert message =~
               "\"run-2\": still in the store after ModC; typed in no test file (a support module?)"

      assert message =~ "unique_run_id"
    end

    test "typed_in/2 lists only the files that type the id between quotes" do
      assert Guard.typed_in(@live, [__ENV__.file]) == [__ENV__.file]
      assert Guard.typed_in("run-leak-guard-" <> "nowhere", [__ENV__.file]) == []
    end
  end
end
