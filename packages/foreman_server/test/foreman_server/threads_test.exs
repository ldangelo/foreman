defmodule ForemanServer.ThreadsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  describe "Thread.from_run/6 (pure)" do
    test "carries branch, pr_url, last_report, session id, constants and run_ids" do
      run = %{
        run_id: "r1",
        task_id: "t1",
        project_id: "p",
        status: "completed",
        pr_url: "https://github.com/o/r/pull/9",
        provider_session_id: "sess-9",
        started_at_ms: 10,
        last_event_at_ms: 20
      }

      worktrees = [
        %{operation_id: "wt-r1-a", branch: "foreman/a", repo_path: "/repo"},
        %{operation_id: "wt-r1-b", branch: "foreman/b", repo_path: "/repo"}
      ]

      review = %{verdict: "partially_met", summary: "half", at: "2026-01-01T00:00:00Z"}
      task = %{task_id: "t1", title: "Fix it"}

      thread = Thread.from_run(run, task, worktrees, {:error, :not_found}, review, ["r1", "r0"])

      assert %Thread{
               id: "run:r1",
               door: :workflow,
               title: "Fix it",
               branch: "foreman/b",
               repo_path: "/repo",
               pr_url: "https://github.com/o/r/pull/9",
               provider_session_id: "sess-9",
               resolved: false,
               steering: "pause_resume",
               run_ids: ["r1", "r0"],
               created_at: 10,
               updated_at: 20,
               last_report: %{verdict: "partially_met", summary: "half"}
             } = thread
    end

    test "run without review has explicit nil last_report; pr falls back to association" do
      run = %{run_id: "r2", project_id: "p", status: "running", pr_url: nil}

      thread =
        Thread.from_run(run, nil, [], {:ok, %{pr_url: "https://x/pull/1"}}, nil, ["r2"])

      assert thread.last_report == nil
      assert thread.pr_url == "https://x/pull/1"
      assert thread.title == "r2"
      assert thread.branch == nil
    end

    test "title fallback: title, then first prompt line, then description line, then id" do
      run = %{run_id: "r3", project_id: "p"}
      build = fn task -> Thread.from_run(run, task, [], {:error, :not_found}, nil, []).title end

      assert build.(%{task_id: "t", title: " ", prompt: "\n\nDo X\nmore", description: "d"}) ==
               "Do X"

      assert build.(%{task_id: "t", title: nil, prompt: nil, description: "Desc\nline2"}) ==
               "Desc"

      assert build.(%{task_id: "t", title: "", prompt: "", description: ""}) == "t"
    end
  end

  describe "Thread.from_jobsite/3 (pure)" do
    test "reads branch, session id and review" do
      jobsite = %{
        jobsite_id: "j1",
        project_id: "p",
        status: "completed",
        branch: "jb",
        repo_path: "/r",
        session_id: "js-1",
        started_at_ms: 1,
        updated_at_ms: 2
      }

      thread =
        Thread.from_jobsite(jobsite, %{task_id: "t9", title: "T"}, %{
          verdict: "met",
          summary: "ok",
          at: "x"
        })

      assert %Thread{
               id: "jobsite:j1",
               door: :jobsite,
               task_id: "t9",
               title: "T",
               branch: "jb",
               provider_session_id: "js-1",
               last_report: %{verdict: "met"}
             } = thread
    end
  end

  describe "facade over real projected events" do
    defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

    defp task(id, extra \\ %{}) do
      %{
        event_type: "TaskCreated",
        payload:
          Map.merge(
            %{
              task_id: id,
              project_id: "p",
              title: "title #{id}",
              status: "open",
              task_type: "implement"
            },
            extra
          )
      }
    end

    defp run_started(run_id, task_id, project \\ "p"),
      do: %{
        event_type: "RunStarted",
        payload: %{run_id: run_id, task_id: task_id, project_id: project}
      }

    defp jobsite(id, extra \\ %{}) do
      %{
        event_type: "JobsiteStarted",
        payload:
          Map.merge(
            %{
              jobsite_id: id,
              repo_path: "/repo",
              strategy: "worktree",
              project_id: "p",
              branch: "jb-#{id}"
            },
            extra
          )
      }
    end

    test "lists both doors, filters by status/door, and get/1 agrees" do
      apply!([
        task("t1"),
        run_started("r1", "t1"),
        %{
          event_type: "WorkerSessionBound",
          payload: %{
            run_id: "r1",
            worker_id: "w",
            provider: "pi",
            provider_session_id: "sess-1"
          }
        },
        %{
          event_type: "WorktreeCreated",
          payload: %{
            operation_id: "wt-r1-p1",
            project_id: "p",
            run_id: "r1",
            phase_id: "p1",
            repo_path: "/repo",
            branch: "foreman/r1"
          }
        },
        %{
          event_type: "PrAssociated",
          payload: %{run_id: "r1", pr_url: "https://github.com/o/r/pull/1"}
        },
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "run",
            subject_id: "r1",
            verdict: "partially_met",
            summary: "half done",
            at: "2026-01-01T00:00:00Z"
          }
        },
        jobsite("j1"),
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "jobsite",
            subject_id: "j1",
            verdict: "met",
            summary: "done",
            at: "2026-01-02T00:00:00Z"
          }
        }
      ])

      threads = Threads.list("p")
      assert Enum.sort(Enum.map(threads, & &1.id)) == ["jobsite:j1", "run:r1"]

      run_thread = Enum.find(threads, &(&1.id == "run:r1"))
      assert run_thread.title == "title t1"
      assert run_thread.branch == "foreman/r1"
      assert run_thread.pr_url == "https://github.com/o/r/pull/1"
      assert run_thread.provider_session_id == "sess-1"
      assert run_thread.last_report.verdict == "partially_met"

      job_thread = Enum.find(threads, &(&1.id == "jobsite:j1"))
      assert job_thread.branch == "jb-j1"
      assert job_thread.last_report.verdict == "met"

      assert [%Thread{id: "jobsite:j1"}] = Threads.list("p", door: :jobsite)
      assert [%Thread{id: "run:r1"}] = Threads.list("p", door: :workflow)
      assert [%Thread{id: "run:r1"}] = Threads.list("p", status: run_thread.status)
      assert Threads.list("other-project") == []
      assert length(Threads.list("p", limit: 1)) == 1

      assert {:ok, ^run_thread} = Threads.get("run:r1")
      assert {:ok, ^job_thread} = Threads.get("jobsite:j1")
    end

    test "a bead-linked jobsite and its task's run appear once" do
      apply!([
        task("t1", %{external_id: "bead-1"}),
        run_started("r1", "t1"),
        jobsite("j1", %{bead_id: "bead-1"}),
        jobsite("j2", %{bead_id: "bead-without-run"})
      ])

      ids = "p" |> Threads.list() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["jobsite:j2", "run:r1"]
      assert {:error, :thread_not_found} = Threads.get("jobsite:j1")
    end

    test "a task with several runs is one thread on its newest run listing all run ids" do
      apply!([task("t1"), run_started("r1", "t1")])
      apply!([run_started("r2", "t1")])

      assert [%Thread{id: id, run_ids: run_ids}] = Threads.list("p")
      assert id in ["run:r1", "run:r2"]
      assert Enum.sort(run_ids) == ["r1", "r2"]
      assert hd(run_ids) == String.replace_prefix(id, "run:", "")
    end

    test "unknown or malformed id is :thread_not_found" do
      assert {:error, :thread_not_found} = Threads.get("run:nope")
      assert {:error, :thread_not_found} = Threads.get("garbage")
      assert {:error, :thread_not_found} = Threads.get("")
    end

    test "jobsite lacking bead_id key does not crash listing" do
      apply!([jobsite("j9", %{})])
      assert [%Thread{id: "jobsite:j9", task_id: nil, title: "j9"}] = Threads.list("p")
    end
  end
end
