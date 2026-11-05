defmodule ForemanServerWeb.Workspace.NavRunsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServerWeb.OperatorDashboard
  alias ForemanServerWeb.OperatorDashboard.RunDTO
  alias ForemanServerWeb.Workspace.NavRuns
  alias ForemanServerWeb.Workspace.NavRuns.{Jobsite, Run}

  defp dto(run_id, overrides \\ []) do
    struct!(
      RunDTO,
      Keyword.merge(
        [
          run_id: run_id,
          status: "running",
          workflow: "plan",
          task_id: :absent,
          started_at_ms: 1_000,
          pr_url: :absent
        ],
        overrides
      )
    )
  end

  defp wt(op, status, overrides \\ []) do
    Map.merge(
      %{
        operation_id: op,
        status: status,
        branch: "feat/#{op}",
        base_ref: "main",
        worktree_path: "/wt/#{op}",
        cleanup: "always"
      },
      Map.new(overrides)
    )
  end

  defp build(dtos, tasks \\ %{}, worktrees \\ %{}, prs \\ %{}),
    do: NavRuns.build_runs(dtos, tasks, worktrees, prs)

  defp no_nil_fields?(struct),
    do: struct |> Map.from_struct() |> Map.values() |> Enum.all?(&(&1 != nil))

  describe "build_runs/4" do
    test "a bare run carries only sentinels, never nil" do
      assert [%Run{} = run] = build([dto("r1", workflow: :absent, started_at_ms: :absent)])

      assert run.run_id == "r1"
      assert run.title == "r1"
      assert run.workflow == :absent
      assert run.started_at_ms == :absent
      assert run.branch == :none
      assert run.worktree == :none
      assert run.pr == :none
      assert run.trd_path == :none
      assert run.thread_id == "run:r1"
      assert no_nil_fields?(run)
    end

    test "title is the task's title, shared with Thread.title/2" do
      tasks = %{"t1" => %{task_id: "t1", title: "Fix login", trd_path: "docs/TRD/x.md"}}
      assert [run] = build([dto("r1", task_id: "t1")], tasks)
      assert run.title == "Fix login"
      assert run.trd_path == "docs/TRD/x.md"

      # task_id set but task unknown: the run id, and the run stays linkable
      assert [%Run{title: "r2"}] = build([dto("r2", task_id: "gone")], tasks)
    end

    test "blank trd_path is :none" do
      tasks = %{"t1" => %{task_id: "t1", title: "T", trd_path: "  "}}
      assert [%Run{trd_path: :none}] = build([dto("r1", task_id: "t1")], tasks)
    end

    test "worktree state mapping" do
      cases = [
        {wt("a", "created", cleanup: "never"), :kept},
        {wt("a", "created", cleanup: "always"), :active},
        {wt("a", "created", cleanup: nil), :active},
        {wt("a", "cleaned"), :removed}
      ]

      for {record, state} <- cases do
        assert [%Run{worktree: worktree} = run] = build([dto("r1")], %{}, %{"r1" => [record]})
        assert worktree.state == state
        assert worktree.path == "/wt/a"
        assert no_nil_fields?(run)
      end

      assert [%Run{worktree: %{cleanup: :none}}] =
               build([dto("r1")], %{}, %{"r1" => [wt("a", "created", cleanup: nil)]})

      assert [%Run{worktree: :none}] = build([dto("r1")], %{}, %{"r1" => []})
    end

    test "branch is the last record with a branch; a later branchless record is skipped" do
      records = [
        wt("a", "cleaned", branch: "first", base_ref: "b1"),
        wt("b", "created", branch: "second", base_ref: nil),
        wt("c", "created", branch: nil)
      ]

      assert [%Run{branch: branch, worktree: worktree}] =
               build([dto("r1")], %{}, %{"r1" => records})

      assert branch == %{name: "second", base: :none}
      # the worktree comes from the SAME record as the branch, never a later branchless one
      assert worktree.path == "/wt/b"

      assert [%Run{branch: %{name: "first", base: "b1"}}] =
               build([dto("r1")], %{}, %{"r1" => [hd(records)]})

      # no record carries a branch: the checkout is still shown, from the newest record
      assert [%Run{branch: :none, worktree: %{path: "/wt/z"}}] =
               build([dto("r1")], %{}, %{"r1" => [wt("z", "created", branch: nil)]})
    end

    test "an unknown worktree status raises, naming it" do
      assert_raise ArgumentError, ~r/"exploded"/, fn ->
        build([dto("r1")], %{}, %{"r1" => [wt("a", "exploded")]})
      end
    end

    test "a run without run_id or status raises" do
      assert_raise ArgumentError, ~r/run_id/, fn -> build([dto(nil)]) end
      assert_raise ArgumentError, ~r/status/, fn -> build([dto("r1", status: nil)]) end
    end

    test "PR links pass through safe_url; the state comes from the PR projection" do
      prs = %{"r1" => %{pr_url: "https://github.com/o/r/pull/7", pr_state: :merged}}

      assert [%Run{pr: %{url: "https://github.com/o/r/pull/7", state: :merged}}] =
               build([dto("r1")], %{}, %{}, prs)

      # the run's own URL wins; no PR projection means state :none
      assert [%Run{pr: %{url: "https://x.test/1", state: :none}}] =
               build([dto("r1", pr_url: "https://x.test/1")])

      assert [%Run{pr: %{state: :none}}] =
               build([dto("r1")], %{}, %{}, %{
                 "r1" => %{pr_url: "https://x.test/2", pr_state: nil}
               })

      assert [%Run{pr: :none}] = build([dto("r1", pr_url: "javascript:alert(1)")])

      assert [%Run{pr: :none}] =
               build([dto("r1")], %{}, %{}, %{"r1" => %{pr_url: "javascript:alert(1)"}})
    end
  end

  describe "build_jobsites/2" do
    defp jobsite(overrides) do
      Map.merge(
        %{
          jobsite_id: "js1",
          status: "running",
          bead_id: nil,
          branch: nil,
          worktree_path: nil
        },
        Map.new(overrides)
      )
    end

    test "title: task title, else bead id, else jobsite id" do
      tasks = %{"bd-1" => %{task_id: "t1", title: "Bead title", external_id: "bd-1"}}

      assert [%Jobsite{title: "Bead title", bead_id: "bd-1"}] =
               NavRuns.build_jobsites([jobsite(bead_id: "bd-1")], tasks)

      assert [%Jobsite{title: "bd-2", bead_id: "bd-2"}] =
               NavRuns.build_jobsites([jobsite(bead_id: "bd-2")], tasks)

      assert [%Jobsite{title: "js1", bead_id: :none} = js] =
               NavRuns.build_jobsites([jobsite([])], tasks)

      assert js.branch == :none
      assert js.worktree_path == :none
      assert js.thread_id == "jobsite:js1"
      assert no_nil_fields?(js)
    end

    test "branch and worktree path pass through" do
      assert [%Jobsite{branch: "feat/x", worktree_path: "/wt/x"}] =
               NavRuns.build_jobsites([jobsite(branch: "feat/x", worktree_path: "/wt/x")], %{})
    end

    test "a jobsite without jobsite_id raises" do
      assert_raise KeyError, fn -> NavRuns.build_jobsites([%{status: "running"}], %{}) end
    end
  end

  describe "read_runs/1 and read_jobsites/1 over a real projection" do
    setup do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "t1",
                     project_id: "p1",
                     title: "Fix login",
                     status: "open",
                     task_type: "implement",
                     external_id: "bd-9"
                   }
                 },
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "r1",
                     project_id: "p1",
                     task_id: "t1",
                     workflow_name: "plan"
                   }
                 },
                 %{
                   event_type: "PhaseStarted",
                   payload: %{
                     phase_id: "r1-ph",
                     run_id: "r1",
                     index: 1,
                     name: "implement",
                     attempt: 1,
                     artifact_template: "a.md"
                   }
                 },
                 %{
                   event_type: "WorktreeCreated",
                   payload: %{
                     operation_id: "op-1",
                     project_id: "p1",
                     run_id: "r1",
                     phase_id: "r1-ph",
                     worktree_path: "/wt/r1",
                     branch: "feat/r1",
                     base_ref: "main",
                     cleanup: "never"
                   }
                 },
                 %{
                   event_type: "PrAssociated",
                   payload: %{
                     run_id: "r1",
                     pr_url: "https://github.com/o/r/pull/1",
                     pr_number: 1,
                     associated_at: 1
                   }
                 },
                 %{
                   event_type: "RunStarted",
                   payload: %{run_id: "r2", project_id: "p1", workflow_name: "plan"}
                 },
                 %{
                   event_type: "RunStarted",
                   payload: %{run_id: "other", project_id: "p2", workflow_name: "plan"}
                 },
                 %{
                   event_type: "JobsiteStarted",
                   payload: %{
                     jobsite_id: "js1",
                     project_id: "p1",
                     repo_path: "/repo",
                     strategy: "local",
                     bead_id: "bd-9",
                     branch: "feat/js1"
                   }
                 },
                 %{
                   event_type: "JobsiteStarted",
                   payload: %{
                     jobsite_id: "js-other",
                     project_id: "p2",
                     repo_path: "/repo",
                     strategy: "local"
                   }
                 }
               ])

      :ok
    end

    test "read_runs/1 returns the rows build_runs/4 builds from the same projection" do
      runs = NavRuns.read_runs("p1")

      assert runs |> Enum.map(& &1.run_id) |> Enum.sort() == ["r1", "r2"]
      r1 = Enum.find(runs, &(&1.run_id == "r1"))
      r2 = Enum.find(runs, &(&1.run_id == "r2"))

      assert r1.title == "Fix login"
      assert r1.workflow == "plan"
      assert r1.branch == %{name: "feat/r1", base: "main"}
      assert r1.worktree == %{path: "/wt/r1", state: :kept, cleanup: "never"}
      assert %{url: "https://github.com/o/r/pull/1"} = r1.pr
      assert r2.title == "r2"
      assert r2.branch == :none
      assert r2.pr == :none

      {:ok, dtos} = OperatorDashboard.list_runs(%{project_id: "p1", detail: :summary})
      tasks = Map.new(ProjectionStore.list_tasks(), &{&1.task_id, &1})
      worktrees = ProjectionStore.worktrees_for_runs(Enum.map(dtos, & &1.run_id))

      assert runs ==
               NavRuns.build_runs(
                 dtos,
                 tasks,
                 worktrees,
                 ProjectionStore.pr_states_for_project("p1")
               )
    end

    test "read_runs/1 reads no per-run phases" do
      parent = self()
      tracer = spawn_link(fn -> count_phase_reads(0) end)

      :erlang.trace_pattern({ProjectionStore, :phases_for_run, 1}, true, [:global])
      :erlang.trace(parent, true, [:call, {:tracer, tracer}])

      try do
        assert length(NavRuns.read_runs("p1")) == 2
        ref = :erlang.trace_delivered(parent)
        assert_receive {:trace_delivered, ^parent, ^ref}
        send(tracer, {:report, parent})
        assert_receive {:phase_reads, 0}
      after
        :erlang.trace(parent, false, [:call])
        :erlang.trace_pattern({ProjectionStore, :phases_for_run, 1}, false, [:global])
      end
    end

    test "read_jobsites/1 keeps this project's jobsites and titles them by bead task" do
      assert [%Jobsite{} = js] = NavRuns.read_jobsites("p1")
      assert js.jobsite_id == "js1"
      assert js.title == "Fix login"
      assert js.bead_id == "bd-9"
      assert js.branch == "feat/js1"
    end
  end

  defp count_phase_reads(count) do
    receive do
      {:trace, _pid, :call, {ProjectionStore, :phases_for_run, _}} -> count_phase_reads(count + 1)
      {:report, from} -> send(from, {:phase_reads, count})
    end
  end
end
