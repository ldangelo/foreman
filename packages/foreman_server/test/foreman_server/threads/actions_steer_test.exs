defmodule ForemanServer.Threads.ActionsSteerTest do
  # `Threads.Actions.steer/3` on both doors: the workflow door queues
  # `run.steer` on the run aggregate; the jobsite door goes through
  # `Jobsite.steer/3` (pause, then resume with the message as the prompt).
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Actions

  @recording_agent Path.join(__DIR__, "../jobsite/support/recording_agent.sh")

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    slot_init = "thread-steer-slot-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "thread-steer-test:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init, capacity: 100}
      })

    on_exit(fn ->
      CommandGateway.dispatch_system(%{
        type: "run_slots.release",
        command_id: "thread-steer-test:release:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init}
      })
    end)

    :ok
  end

  describe "workflow door" do
    test "queues the message on the run and echoes the supplied message_id" do
      run_id = start_run!()

      assert {:ok, %{message_id: "m-1", mode: :pause_resume}} =
               Actions.steer("run:" <> run_id, "use the cache", message_id: "m-1")

      queued = await_event("RunSteerQueued", :run_id, run_id)
      assert field(queued, :message_id) == "m-1"
      assert field(queued, :text) == "use the cache"
      assert field(queued, :resume) == true

      assert [%{message_id: "m-1", text: "use the cache"}] =
               ProjectionStore.pending_steering(run_id)
    end

    test "resume: false is carried on the event; generated ids are unique" do
      run_id = start_run!()

      assert {:ok, %{message_id: a}} = Actions.steer("run:" <> run_id, "one", resume: false)
      assert {:ok, %{message_id: b}} = Actions.steer("run:" <> run_id, "two")
      assert a != b

      assert field(await_event("RunSteerQueued", :run_id, run_id), :resume) == false
    end

    test "re-sending the same message_id queues it once" do
      run_id = start_run!()
      opts = [message_id: "dup"]

      assert {:ok, _} = Actions.steer("run:" <> run_id, "same", opts)
      assert {:ok, _} = Actions.steer("run:" <> run_id, "same", opts)
      await_event("RunSteerQueued", :run_id, run_id)

      assert [%{message_id: "dup"}] = ProjectionStore.pending_steering(run_id)
    end

    test "a terminal run is {:not_steerable, status} on the same typed error" do
      run_id = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", :run_id, run_id)

      assert {:error, {:not_steerable, "cancelled"}} = Actions.steer("run:" <> run_id, "late")
      assert ProjectionStore.pending_steering(run_id) == []
    end

    test "blank, non-string and oversize text are rejected before dispatch" do
      run_id = start_run!()

      assert {:error, {:invalid_text, :blank}} = Actions.steer("run:" <> run_id, "  ")
      assert {:error, {:invalid_text, :blank}} = Actions.steer("run:" <> run_id, nil)

      assert {:error, {:invalid_text, :too_long}} =
               Actions.steer("run:" <> run_id, String.duplicate("x", 8001))

      assert ProjectionStore.pending_steering(run_id) == []
    end
  end

  test "unknown thread" do
    assert {:error, :thread_not_found} = Actions.steer("run:nope-steer", "hi")
    assert {:error, :thread_not_found} = Actions.steer("jobsite:nope-steer", "hi")
  end

  describe "jobsite door" do
    setup do
      repo = tmp_repo!()
      log = Path.join(System.tmp_dir!(), "thread-steer-#{System.unique_integer([:positive])}.log")
      agent_bin = recording_binary!(log)

      on_exit(fn ->
        File.rm_rf(repo)
        File.rm(log)
        File.rm(agent_bin)
      end)

      {:ok, repo: repo, log: log, agent_bin: agent_bin}
    end

    test "steers a running jobsite: paused with reason steer, resumed with the message", ctx do
      id = start_running!(ctx.repo, ctx.agent_bin)

      assert {:ok, %{message_id: "js-m", mode: :pause_resume}} =
               Actions.steer("jobsite:" <> id, "switch to JWT", message_id: "js-m")

      assert field(await_event("JobsitePaused", :jobsite_id, id), :reason) == "steer"
      await_event("JobsiteCompleted", :jobsite_id, id)

      invocations = ctx.log |> File.read!() |> String.split("--invocation--\n", trim: true)
      assert List.last(invocations) =~ "switch to JWT"
    end

    test "a terminal jobsite is {:not_steerable, status}; blank text pauses nothing", ctx do
      id = start_running!(ctx.repo, ctx.agent_bin)

      assert {:error, {:invalid_text, :blank}} = Actions.steer("jobsite:" <> id, " ")
      assert Jobsite.Executor.pid_for(id) != nil

      pid = Jobsite.Executor.pid_for(id)
      ref = Process.monitor(pid)
      :ok = Jobsite.cancel(id, "done")
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000
      await_event("JobsiteCancelled", :jobsite_id, id)

      assert {:error, {:not_steerable, "cancelled"}} = Actions.steer("jobsite:" <> id, "late")
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unique(prefix), do: "#{prefix}-thread-steer-#{System.unique_integer([:positive])}"

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

    assert {:ok, _} =
             CommandRouter.dispatch_run_start(project_id, %{
               run_id: run_id,
               task_id: unique("task"),
               workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
               phase_specs: [%{phase_id: "phase-1", kind: "command"}],
               approval_id: unique("approval")
             })

    await_event("RunStarted", :run_id, run_id)
    run_id
  end

  defp recording_binary!(log) do
    path = Path.join(System.tmp_dir!(), "rec-agent-#{System.unique_integer([:positive])}.sh")

    File.write!(
      path,
      "#!/bin/sh\nFAKE_AGENT_PROMPT_LOG=#{log} exec #{@recording_agent} \"$@\"\n"
    )

    File.chmod!(path, 0o755)
    path
  end

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "thread-steer-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_o, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_o, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_o, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    path
  end

  defp start_running!(repo, agent_bin) do
    agent =
      Agents.pi("x",
        binary: agent_bin,
        env: %{
          "FAKE_AGENT_SESSION_FIRST" => "1",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "30"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "go",
        max_iterations: 1,
        completion_signal: "NEVER"
      )

    await_event("JobsiteIterationStarted", :jobsite_id, id)
    # A steer pauses then resumes: the resume needs the agent's provider session (foreman-cm8nv).
    ForemanServer.TestSupport.JobsiteSession.await!(id)
    id
  end

  defp field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> data[to_string(key)]
    end
  end

  defp await_event(type, key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, key) == id, do: data, else: await_event(type, key, id)

      {:projection_event, _other} ->
        await_event(type, key, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end
end
