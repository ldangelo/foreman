defmodule ForemanServer.Threads.FinderTest do
  # Deterministic thread lookup (`Threads.Finder`), the REST/MCP surfaces over
  # it, and `Threads.Actions.follow_up/2` (never starts a run or a jobsite).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ForemanServerWeb.Endpoint
  @token "finder-test-token"

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter
  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunAdmission
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads.Actions
  alias ForemanServer.Threads.Finder
  alias ForemanServer.Threads.Finder.Candidate

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    {:ok, conn: put_req_header(build_conn(), "authorization", "Bearer " <> @token)}
  end

  describe "find/2" do
    setup do
      apply!([
        task("tA", %{external_id: "bead-1", title: "Add healthz route"}),
        run("rA", "tA"),
        task("tB", %{title: "Add healthz endpoint"}),
        run("rB", "tB"),
        resolved("run:rB"),
        task("tC", %{title: "Fix login bug"}),
        run("rC", "tC"),
        worktree("rC", "fix/login"),
        pr("rC", "https://github.com/o/r/pull/42"),
        task("tD", %{title: "Add healthz route endpoint"}),
        run("rD", "tD"),
        %{event_type: "RunCancelled", payload: %{run_id: "rD", task_id: "tD", project_id: "p"}},
        %{event_type: "RunDeleted", payload: %{run_id: "rD", task_id: "tD", project_id: "p"}}
      ])
    end

    test "external_id, branch and PR matches are exact" do
      assert {:ok, [%Candidate{thread_id: "run:rA", reason: :external_id, score: 1.0}]} =
               Finder.find("p", external_id: "bead-1")

      assert {:ok, [%Candidate{thread_id: "run:rC", reason: :branch}]} =
               Finder.find("p", branch: "fix/login")

      for pr <- ["https://github.com/o/r/pull/42", "42", "#42"] do
        assert {:ok, [%Candidate{thread_id: "run:rC", reason: :pr}]} = Finder.find("p", pr: pr)
      end

      assert {:ok, []} = Finder.find("p", pr: "4")
      assert {:ok, []} = Finder.find("other-project", external_id: "bead-1")
    end

    test "text matches skip resolved and deleted threads" do
      assert {:ok, [%Candidate{thread_id: "run:rA", reason: :text, score: score}]} =
               Finder.find("p", text: "healthz route endpoint")

      assert score >= 0.5
    end

    test "resolved threads still answer an exact match" do
      apply!([task("tB2", %{external_id: "bead-2", title: "Resolved one"}), run("rB2", "tB2")])
      apply!([resolved("run:rB2")])

      assert {:ok, [%Candidate{thread_id: "run:rB2", reason: :external_id, resolved: true}]} =
               Finder.find("p", external_id: "bead-2")
    end

    test "a text score below 0.5 is no candidate" do
      assert {:ok, []} = Finder.find("p", text: "healthz database migration cache layer")
    end

    test "exact matches outrank text matches" do
      assert {:ok, [%Candidate{thread_id: "run:rC", reason: :branch}, %Candidate{} = text]} =
               Finder.find("p", branch: "fix/login", text: "healthz route endpoint")

      assert text.reason == :text
      assert text.thread_id == "run:rA"
    end

    test "no criteria (empty or blank) is an error" do
      assert {:error, :no_criteria} = Finder.find("p", [])
      assert {:error, :no_criteria} = Finder.find("p", text: "  ", branch: "")
      assert {:error, :no_criteria} = Finder.find("p", %{})
    end
  end

  describe "ordering" do
    test "ties resolve by newest updated_at, then id; repeated calls agree" do
      apply!([
        task("t1", %{title: "shared words here"}),
        task("t2", %{title: "shared words here"}),
        run("r-old", "t1", 10),
        run("r-new", "t2", 20)
      ])

      first = Finder.find("p", text: "shared words here")
      assert first == Finder.find("p", text: "shared words here")
      assert {:ok, [%{thread_id: "run:r-new"}, %{thread_id: "run:r-old"}]} = first
    end

    test "limit caps the result" do
      apply!([
        task("t1", %{title: "shared words here"}),
        task("t2", %{title: "shared words here"}),
        run("r1", "t1"),
        run("r2", "t2")
      ])

      assert {:ok, [_]} = Finder.find("p", text: "shared words here", limit: 1)
    end
  end

  describe "REST and MCP" do
    setup do
      apply!([
        task("tA", %{external_id: "bead-1", title: "Add healthz route"}),
        run("rA", "tA")
      ])
    end

    test "GET /api/projects/:id/threads/find returns candidates, 400 without criteria", %{
      conn: conn
    } do
      body =
        conn
        |> get("/api/projects/p/threads/find?external_id=bead-1")
        |> json_response(200)

      assert [%{"thread_id" => "run:rA", "reason" => "external_id", "suggested" => false}] =
               body["candidates"]

      assert %{"candidates" => [%{"reason" => "text", "suggested" => true}]} =
               conn |> get("/api/projects/p/threads/find?q=healthz+route") |> json_response(200)

      assert %{"error" => "invalid_params"} =
               conn |> get("/api/projects/p/threads/find") |> json_response(400)

      # the list route still answers: `find` is not captured as an id
      assert %{"threads" => [_]} =
               conn |> get("/api/projects/p/threads") |> json_response(200)
    end

    test "foreman_thread_find is a read tool with the same answer" do
      names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
      assert "foreman_thread_find" in names
      assert Policy.authorized?("foreman_thread_find")

      assert {:ok, [%{"thread_id" => "run:rA", "reason" => "external_id"}]} =
               Tools.call_tool("foreman_thread_find", %{project_id: "p", external_id: "bead-1"})

      for args <- [%{project_id: "p"}, %{project_id: ""}] do
        assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
                 Tools.call_tool("foreman_thread_find", args)
      end
    end
  end

  describe "Actions.follow_up/2" do
    setup do
      :ok = ProjectionStore.subscribe(replay_existing: false)
      slot = "follow-up-slot-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "run_slots.acquire",
          command_id: "follow-up-test:#{slot}",
          aggregate_id: "run_slots:global",
          payload: %{run_id: slot, capacity: 100}
        })

      on_exit(fn ->
        CommandGateway.dispatch_system(%{
          type: "run_slots.release",
          command_id: "follow-up-test:release:#{slot}",
          aggregate_id: "run_slots:global",
          payload: %{run_id: slot}
        })
      end)
    end

    test "a live thread is steered; no run or jobsite is started" do
      {run_id, _project_id} = start_run!()
      drain_events()

      assert {:ok, %{message_id: _, mode: :pause_resume}} =
               Actions.follow_up("run:" <> run_id, "also add tests")

      assert %{} = await_event("RunSteerQueued", run_id)
      assert [%{text: "also add tests"}] = ProjectionStore.pending_steering(run_id)
      assert Enum.map(ProjectionStore.list_runs(), & &1.run_id) == [run_id]
      refute_received {:projection_event, %{event_type: "RunStarted"}}
      refute_received {:projection_event, %{event_type: "JobsiteStarted"}}
    end

    test "a terminal thread with a branch needs a new run, with the session id" do
      {run_id, project_id} = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", run_id)

      apply!([
        worktree(run_id, "feat/x", project_id),
        %{
          event_type: "WorkerSessionBound",
          payload: %{
            run_id: run_id,
            worker_id: "w1",
            provider: "pi",
            model: "m",
            provider_session_id: "sess-7"
          }
        }
      ])

      drain_events()

      assert {:error, {:needs_new_run, %{branch: "feat/x", session_id: "sess-7"}}} =
               Actions.follow_up("run:" <> run_id, "continue")

      refute_received {:projection_event, %{event_type: "RunStarted"}}
      refute_received {:projection_event, %{event_type: "RunSteerQueued"}}
      assert ProjectionStore.pending_steering(run_id) == []
    end

    test "session_id is nil when the thread has none" do
      {run_id, project_id} = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", run_id)
      apply!([worktree(run_id, "feat/y", project_id)])

      assert {:error, {:needs_new_run, %{branch: "feat/y", session_id: nil}}} =
               Actions.follow_up("run:" <> run_id, "continue")
    end

    test "a resolved thread is :thread_resolved, never implicitly reopened" do
      {run_id, _project_id} = start_run!()
      apply!([resolved("run:" <> run_id)])
      drain_events()

      assert {:error, :thread_resolved} = Actions.follow_up("run:" <> run_id, "hello")
      refute_received {:projection_event, %{event_type: "RunSteerQueued"}}
      refute_received {:projection_event, %{event_type: "ThreadReopened"}}
      assert ProjectionStore.pending_steering(run_id) == []
    end

    test "unknown thread and terminal thread without a branch keep steer's errors" do
      assert {:error, :thread_not_found} = Actions.follow_up("run:nope", "x")

      {run_id, _} = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", run_id)

      assert {:error, {:not_steerable, "cancelled"}} = Actions.follow_up("run:" <> run_id, "x")
    end
  end

  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp task(id, extra) do
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

  defp run(run_id, task_id, at \\ nil) do
    base = %{run_id: run_id, task_id: task_id, project_id: "p"}
    payload = if at, do: Map.put(base, :started_at_ms, at), else: base
    %{event_type: "RunStarted", payload: payload}
  end

  defp worktree(run_id, branch, project_id \\ "p") do
    %{
      event_type: "WorktreeCreated",
      payload: %{
        operation_id: "wt-#{run_id}",
        project_id: project_id,
        run_id: run_id,
        phase_id: "phase-1",
        repo_path: "/repo",
        branch: branch
      }
    }
  end

  defp pr(run_id, url),
    do: %{event_type: "PrAssociated", payload: %{run_id: run_id, pr_url: url}}

  defp resolved(thread_id) do
    %{
      event_type: "ThreadResolved",
      payload: %{
        thread_id: thread_id,
        project_id: "p",
        resolved_by: "operator",
        at: "2026-01-01T00:00:00Z"
      }
    }
  end

  defp start_run! do
    project_id = unique("project")
    run_id = unique("run")

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: "register:#{project_id}",
               type: "project.register",
               payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
             })

    assert {:ok, result} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: unique("task"),
               workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
               phase_specs: [%{phase_id: "phase-1", kind: "command"}],
               approval_id: unique("approval")
             })

    refute result in [:queued, :slot_queued]
    await_event("RunStarted", run_id)
    {run_id, project_id}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp drain_events do
    receive do
      {:projection_event, _} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> data[to_string(key)]
    end
  end

  defp await_event(type, run_id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, :run_id) == run_id, do: data, else: await_event(type, run_id)

      {:projection_event, _other} ->
        await_event(type, run_id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end
end
