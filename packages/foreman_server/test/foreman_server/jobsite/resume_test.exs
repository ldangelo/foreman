defmodule ForemanServer.Jobsite.ResumeTest do
  # Headline new-behavior proof: a jobsite's executor is hard-killed mid-run,
  # and `Jobsite.resume/1` rehydrates authoritative state from the event
  # stream (not the projection, not process memory) and continues the same
  # agent session in the same worktree to completion.
  #
  # No mocks: a real git repo, the real event store (Postgres), the real
  # Jobsite aggregate/projection/executor, and a real spawned process (a
  # fake Pi-shaped shell script standing in for the agent CLI).
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Jobsite}
  alias ForemanServer.Jobsite.{Agents, Executor, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_output, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_output, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp wait_until(fun, deadline_ms \\ 5_000, interval_ms \\ 25) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(fun, deadline, interval_ms)
  end

  defp do_wait_until(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(interval_ms)
        do_wait_until(fun, deadline, interval_ms)
      end
    end
  end

  test "crash resume: rehydrates from the event stream and continues the same session" do
    repo = tmp_repo!()

    # Iteration 2's fake-agent process sleeps for FAKE_AGENT_SLEEP_SECS,
    # holding the jobsite open at iteration_index == 2 (iteration_open? ==
    # true) for a wide, stable window -- giving the test a reliable moment to
    # capture state and hard-kill the executor mid-iteration, instead of
    # racing a near-instantaneous agent process.
    fake_agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{
          "FAKE_AGENT_TEXT" => "did some work",
          "FAKE_AGENT_SLEEP_ON_RUN" => "2",
          "FAKE_AGENT_SLEEP_SECS" => "5"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: fake_agent,
        prompt: "go",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 2 end)

    projected = Jobsite.get(id)
    wt = projected.worktree_path
    sid = projected.session_id
    assert is_binary(sid) and sid != ""

    executor_pid = Executor.pid_for(id)
    assert is_pid(executor_pid)
    ref = Process.monitor(executor_pid)
    Process.exit(executor_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^executor_pid, :killed}, 2_000
    wait_until(fn -> Executor.pid_for(id) == nil end)

    still_running = Jobsite.get(id)
    assert still_running.status == "running"
    assert still_running.iteration_index == 2

    assert {:ok, result} = Jobsite.resume(id)
    assert Enum.map(result.iterations, & &1.index) == [1, 2, 3]
    assert Enum.at(result.iterations, 1).status == :failed

    {:ok, events} = EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999)

    iteration_started =
      events
      |> Enum.filter(&(&1.event_type == "JobsiteIterationStarted"))
      |> Enum.map(& &1.data)

    field = fn data, key -> Map.get(data, key) || Map.get(data, to_string(key)) end

    indices = Enum.map(iteration_started, &field.(&1, :index))
    assert indices == Enum.sort(indices)
    assert indices == Enum.uniq(indices)

    iteration_2 = Enum.find(iteration_started, &(field.(&1, :index) == 2))
    assert field.(iteration_2, :resumed_session_id) == sid

    assert Jobsite.get(id).worktree_path == wt

    {log, 0} = System.cmd("git", ["-C", repo, "log", "--oneline", "--all"])
    assert log =~ "Jobsite #{id}"

    {branches, 0} = System.cmd("git", ["-C", repo, "branch", "--list", "jobsite/*"])
    assert String.trim(branches) == ""
  end

  test "pause: Jobsite.pause/2 interrupts a running jobsite instead of a hard kill" do
    repo = tmp_repo!()

    # Iteration 1 sleeps so the test has a stable window to call pause/2
    # before the agent process would naturally complete.
    fake_agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{
          "FAKE_AGENT_TEXT" => "did some work",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "5"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: fake_agent,
        prompt: "go",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 1 end)

    assert :ok = Jobsite.pause(id, "operator requested pause")

    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)

    paused = Jobsite.get(id)
    assert paused.status == "paused"
    assert paused.terminal? == false

    assert {:ok, result} = Jobsite.resume(id)
    assert length(result.iterations) >= 1
  end

  test "pause during the final iteration of a default (max_iterations: 1) run resumes to completion" do
    repo = tmp_repo!()

    fake_agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{
          "FAKE_AGENT_TEXT" => "did some work",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "5"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: fake_agent,
        prompt: "go",
        completion_signal: "NEVER"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 1 end)
    assert :ok = Jobsite.pause(id, "pause at the cap")
    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)

    # The resumed iteration is #2, past the limit the jobsite started with. The
    # aggregate used to reject it, ending an accepted resume as `failed`.
    assert {:ok, result} = Jobsite.resume(id)
    assert Enum.map(result.iterations, & &1.index) |> List.last() == 2
    wait_until(fn -> Jobsite.get(id).status == "completed" end)
  end

  test "a resumed jobsite reads as running again, and can then be cancelled" do
    repo = tmp_repo!()

    fake_agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{
          "FAKE_AGENT_TEXT" => "did some work",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "5"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: fake_agent,
        prompt: "go",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 1 end)
    assert :ok = Jobsite.pause(id, "pause")
    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)

    assert {:ok, ^id} = Jobsite.resume_async(id)
    wait_until(fn -> Jobsite.get(id).status == "running" end)

    assert :ok = Jobsite.cancel(id, "stop")
    wait_until(fn -> Jobsite.get(id).status == "cancelled" end, 15_000)
  end

  test "a pause/cancel intent left by a previous run of the same id does not hit the new run" do
    repo = tmp_repo!()
    id = "js-stale-intent-#{System.unique_integer([:positive])}"

    ForemanServer.Jobsite.Control.request(id, {:cancel, "left over"})

    {:ok, _pid} =
      ForemanServer.Jobsite.Supervisor.start_jobsite(id,
        reply_to: self(),
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: Agents.pi("x", binary: @fake_agent, env: %{"FAKE_AGENT_TEXT" => "ok"}),
        prompt: "go",
        completion_signal: "NEVER"
      )

    assert_receive {:jobsite, ^id, {:ok, %{iterations: [_ | _]}}}, 10_000
    wait_until(fn -> Jobsite.get(id).status == "completed" end)
  end

  test "signal: the loop stops as soon as the completion signal is seen" do
    repo = tmp_repo!()

    fake_agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{"FAKE_AGENT_TEXT" => "<promise>COMPLETE</promise>"}
      )

    assert {:ok, result} =
             Jobsite.run(
               repo_path: repo,
               strategy: :merge_to_head,
               sandbox: Sandboxes.host(),
               agent: fake_agent,
               prompt: "go",
               max_iterations: 3,
               completion_signal: "<promise>COMPLETE</promise>"
             )

    assert length(result.iterations) == 1
    assert result.status == :signalled
  end
end
