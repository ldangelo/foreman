defmodule ForemanServer.Jobsite.ResumeSessionTest do
  # foreman-cm8nv. A resume continues the agent's OWN conversation (`--resume <session>`); the
  # original prompt is never persisted, only its digest. A jobsite whose first iteration was cut
  # off by a crash used to have no provider session on record (it was written only when an
  # iteration finished), so `Continue.` went to a BLANK agent that found nothing to continue and
  # the jobsite ended `completed`, worktree untouched.
  #
  # Now the session is recorded while the iteration runs, a resume carries it, and a resume with no
  # session on record is refused with a typed error instead of being run.
  #
  # Real git repo, real event store, real executor; the agent CLI is a shell script that records the
  # arguments (session flag and prompt) of every invocation.
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Jobsite}
  alias ForemanServer.Jobsite.{AgentRunner, Agents, Control, Error, Executor, Sandboxes}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.OrphanReaper

  @recording_agent Path.join(__DIR__, "support/recording_agent.sh")

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    repo = tmp_repo!()
    log = Path.join(System.tmp_dir!(), "session-#{System.unique_integer([:positive])}.log")
    agent_bin = recording_binary!(log)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm(log)
      File.rm(agent_bin)
    end)

    {:ok, repo: repo, log: log, agent_bin: agent_bin}
  end

  # The agent's env is deliberately not persisted, so a resumed iteration cannot see env vars; the
  # log path is baked into a per-test wrapper binary instead.
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
    path = Path.join(System.tmp_dir!(), "jobsite-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_o, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_o, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_o, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    path
  end

  # A jobsite whose only iteration holds its agent open for 30 s: a stable window to interrupt.
  # `env` decides whether (and as what) the agent reports its session before it sleeps.
  defp start_sleeping!(repo, agent_bin, env) do
    agent =
      Agents.pi("x",
        binary: agent_bin,
        env: Map.merge(%{"FAKE_AGENT_SLEEP_ON_RUN" => "1", "FAKE_AGENT_SLEEP_SECS" => "30"}, env)
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

    id
  end

  defp kill_executor!(id) do
    pid = Executor.pid_for(id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    wait_until(fn -> Executor.pid_for(id) == nil end)
  end

  # The agent a killed executor leaves behind sleeps on; a test that never resumes reaps it.
  defp reap_orphan_on_exit(id) do
    path = Jobsite.get(id).worktree_path
    on_exit(fn -> OrphanReaper.reap(path) end)
  end

  defp await_event(type, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if (data[:jobsite_id] || data["jobsite_id"]) == id,
          do: data,
          else: await_event(type, id)

      {:projection_event, _other} ->
        await_event(type, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  defp await_first_invocation!(log) do
    wait_until(fn -> File.exists?(log) and File.read!(log) != "" end, 30_000)
  end

  defp wait_until(fun, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(25)
        do_wait_until(fun, deadline)
    end
  end

  defp invocations(log), do: log |> File.read!() |> String.split("--invocation--\n", trim: true)

  defp field(data, key), do: data[key] || data[to_string(key)]

  # The fake CLI itself (not the recording wrapper): `AgentRunner` is driven directly below.
  defp fake_agent(env) do
    Agents.pi("x",
      binary: Path.join(__DIR__, "support/fake_agent.sh"),
      env: Map.merge(%{"FAKE_AGENT_SESSION_FIRST" => "1"}, env)
    )
  end

  describe "a crash in the FIRST iteration, after the agent reported its session" do
    test "the session was recorded before any iteration finished, and the resume continues it",
         %{repo: repo, log: log, agent_bin: agent_bin} do
      id =
        start_sleeping!(repo, agent_bin, %{
          "FAKE_AGENT_SESSION_FIRST" => "1",
          "FAKE_AGENT_SESSION_ID" => "sess-crash-1"
        })

      await_first_invocation!(log)
      bound = await_event("JobsiteSessionBound", id)
      assert field(bound, :session_id) == "sess-crash-1"
      assert field(bound, :index) == 1

      # Recorded while the iteration is still open: no iteration has finished.
      projected = Jobsite.get(id)
      assert projected.session_id == "sess-crash-1"
      assert projected.iteration_index == 1
      assert projected.iterations == []

      kill_executor!(id)
      assert Jobsite.get(id).status == "running"

      # The authoritative state a resume reads carries it too.
      assert {:ok, %{session_id: "sess-crash-1", iteration_open?: true}} =
               Executor.check_resumable(id)

      assert {:ok, result} = Jobsite.resume(id)
      wait_until(fn -> Jobsite.get(id).status == "completed" end)
      assert Enum.map(result.iterations, & &1.index) == [1, 2]

      # The resumed agent was handed THAT session (`--session` is pi's `--resume`), and the
      # default continuation prompt: not a blank session.
      assert [_first, resumed] = invocations(log)
      assert resumed =~ "--session\nsess-crash-1\n"
      assert resumed =~ "Continue."

      {:ok, events} = EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999)

      started =
        events
        |> Enum.filter(&(&1.event_type == "JobsiteIterationStarted"))
        |> Map.new(&{field(&1.data, :index), field(&1.data, :resumed_session_id)})

      assert started == %{1 => nil, 2 => "sess-crash-1"}
      assert Enum.count(events, &(&1.event_type == "JobsiteSessionBound")) == 1
    end
  end

  describe "a crash before the agent reported any session" do
    setup %{repo: repo, log: log, agent_bin: agent_bin} do
      # No FAKE_AGENT_SESSION_FIRST: the agent sleeps before it says anything.
      id = start_sleeping!(repo, agent_bin, %{})
      await_first_invocation!(log)
      assert Jobsite.get(id)[:session_id] == nil
      kill_executor!(id)
      reap_orphan_on_exit(id)
      {:ok, id: id}
    end

    test "resume is refused with :no_session, runs nothing, and does not complete the jobsite",
         %{id: id, log: log} do
      assert {:error, %Error{code: :no_session, message: message, details: details}} =
               Jobsite.resume(id)

      assert message =~ "no provider session"
      assert details.jobsite_id == id

      assert {:error, %Error{code: :no_session}} = Jobsite.resume_async(id)
      assert {:error, %Error{code: :no_session}} = Jobsite.resume_async(id, prompt: "recall X")
      assert {:error, %Error{code: :no_session}} = Executor.check_resumable(id)

      # `Continue.` was never sent to a blank agent: the original invocation is the only one.
      assert length(invocations(log)) == 1
      assert Executor.pid_for(id) == nil

      # And the jobsite did not turn into the silent, empty `completed` the bug produced.
      assert Jobsite.get(id).status == "running"
      {:ok, events} = EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999)
      refute Enum.any?(events, &(&1.event_type in ["JobsiteCompleted", "JobsiteFailed"]))
    end
  end

  describe "steering a running jobsite whose agent has not reported a session" do
    test "is refused BEFORE anything is paused, so the running agent is not lost",
         %{repo: repo, log: log, agent_bin: agent_bin} do
      id = start_sleeping!(repo, agent_bin, %{})
      await_first_invocation!(log)
      pid = Executor.pid_for(id)
      assert is_pid(pid)

      assert {:error, %Error{code: :no_session}} = Jobsite.steer(id, "do something else")

      # Nothing was requested of the executor: it is alive, running, and has no pause pending.
      assert Executor.pid_for(id) == pid
      assert Control.intent(id) == :none
      assert Jobsite.get(id).status == "running"
      assert length(invocations(log)) == 1

      assert :ok = Jobsite.cancel(id, "test cleanup")
      wait_until(fn -> Jobsite.get(id).status == "cancelled" end, 25_000)
    end
  end

  describe "AgentRunner reports and keeps the provider session" do
    setup %{repo: repo} do
      {:ok, sandbox} =
        Jobsite.create_sandbox(repo_path: repo, strategy: :head, sandbox: Sandboxes.host())

      {:ok, sandbox: sandbox}
    end

    test "on_session is told the session while the iteration is still running, once, by the caller",
         %{sandbox: sandbox} do
      agent =
        fake_agent(%{
          "FAKE_AGENT_SESSION_ID" => "sess-live",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "3"
        })

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(agent, "go", sandbox,
            index: 1,
            on_session: fn session_id -> send(test_pid, {:reported, session_id, self()}) end
          )
        end)

      # Heard long before the 3 s iteration ends, from the process that called `run/4`.
      assert_receive {:reported, "sess-live", reporter}, 2_000
      assert reporter == task.pid
      assert Task.yield(task, 0) == nil

      assert {:ok, result} = Task.await(task, 20_000)
      assert result.session_id == "sess-live"
      refute_received {:reported, _, _}
    end

    test "a run that starts FROM a session has its record already and reports nothing",
         %{sandbox: sandbox} do
      agent = fake_agent(%{"FAKE_AGENT_SESSION_ID" => "sess-new"})
      test_pid = self()

      assert {:ok, %{status: status}} =
               AgentRunner.run(agent, "go", sandbox,
                 index: 2,
                 resume_session: "sess-old",
                 on_session: fn session_id -> send(test_pid, {:reported, session_id}) end
               )

      assert status in [:completed, :signalled]
      refute_received {:reported, _}
    end

    test "a paused run keeps the session the harness had reported, with no on_session at all",
         %{sandbox: sandbox} do
      agent =
        fake_agent(%{
          "FAKE_AGENT_SESSION_ID" => "sess-paused",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "30"
        })

      # The pause is requested only once the harness itself holds the session, so the result's
      # id can only have come from the cancelled run's own report, not from a watcher.
      intent = fn ->
        reported? =
          [providers: [:pi], states: [:running]]
          |> Jido.Harness.Run.list()
          |> Enum.any?(&(&1.provider_session_id == "sess-paused"))

        if reported?, do: {:pause, "test pause"}, else: :none
      end

      assert {:ok, %{status: :cancelled, session_id: "sess-paused"}} =
               AgentRunner.run(agent, "go", sandbox, index: 1, intent_fun: intent)
    end
  end
end
