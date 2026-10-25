defmodule ForemanServer.Jobsite.SteerTest do
  # Steering v1: `Jobsite.steer/3` = pause (reason "steer"), wait for the
  # executor to exit, resume with the operator message as the next prompt.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Executor, Sandboxes}
  alias ForemanServer.ProjectionStore

  @recording_agent Path.join(__DIR__, "support/recording_agent.sh")

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    repo = tmp_repo!()
    log = Path.join(System.tmp_dir!(), "steer-#{System.unique_integer([:positive])}.log")
    agent_bin = recording_binary!(log)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm(log)
      File.rm(agent_bin)
    end)

    {:ok, repo: repo, log: {log, agent_bin}}
  end

  # The agent's env is deliberately not persisted, so a resumed iteration cannot
  # see env vars; the log path is baked into a per-test wrapper binary instead.
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
    path = Path.join(System.tmp_dir!(), "jobsite-steer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_o, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_o, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_o, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    path
  end

  defp start_running!(repo, {log, agent_bin}) do
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

    await_event("JobsiteIterationStarted", id)

    # `JobsiteIterationStarted` is recorded before the agent process exists. Pausing in that
    # gap cancels an iteration that never ran, so the prompt log would hold only the resumed
    # invocation. Wait until the agent has really started (it logs its prompt first thing).
    ForemanServer.TestSupport.Eventually.await(
      fn -> match?({:ok, "--invocation--" <> _}, File.read(log)) end,
      timeout: 30_000,
      message: "the agent process never started"
    )

    # A pause-then-resume needs the provider session the agent reported (foreman-cm8nv).
    ForemanServer.TestSupport.JobsiteSession.await!(id)

    id
  end

  defp field(data, key), do: data[key] || data[to_string(key)]

  # Returns the event data of the next `type` event for `id`, collecting nothing else.
  defp await_event(type, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, :jobsite_id) == id, do: data, else: await_event(type, id)

      {:projection_event, _other} ->
        await_event(type, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  defp invocations(log), do: log |> File.read!() |> String.split("--invocation--\n", trim: true)

  test "steering a running jobsite pauses it, then resumes with the message", %{
    repo: repo,
    log: log
  } do
    id = start_running!(repo, log)

    assert {:ok, ^id} = Jobsite.steer(id, "switch to JWT", timeout_ms: 20_000)

    paused = await_event("JobsitePaused", id)
    assert field(paused, :reason) == "steer"

    # ordering: the paused event precedes the resumed iteration's start
    resumed = await_event("JobsiteIterationStarted", id)
    assert field(resumed, :index) == 2

    await_event("JobsiteCompleted", id)

    [first, resumed_invocation] = invocations(elem(log, 0))
    assert first =~ "go"
    assert resumed_invocation =~ "switch to JWT"
    refute resumed_invocation =~ "Continue."
  end

  test "steering a paused jobsite resumes it directly with the message", %{repo: repo, log: log} do
    id = start_running!(repo, log)
    pid = Executor.pid_for(id)
    ref = Process.monitor(pid)
    :ok = Jobsite.pause(id, "manual")
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000

    assert {:ok, ^id} = Jobsite.steer(id, "now use sessions")
    await_event("JobsiteCompleted", id)

    assert List.last(invocations(elem(log, 0))) =~ "now use sessions"
  end

  test "a terminal jobsite is not steerable and a bad message pauses nothing", %{
    repo: repo,
    log: log
  } do
    id = start_running!(repo, log)

    # blank text is refused before the running jobsite is paused
    assert {:error, %Error{code: :spec_option_invalid}} = Jobsite.steer(id, " ")
    assert Executor.pid_for(id) != nil

    pid = Executor.pid_for(id)
    ref = Process.monitor(pid)
    :ok = Jobsite.cancel(id, "done with it")
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000
    await_event("JobsiteCancelled", id)

    assert {:error, {:not_steerable, "cancelled"}} = Jobsite.steer(id, "too late")
  end

  test "unknown id is jobsite_not_found" do
    assert {:error, %Error{code: :jobsite_not_found}} = Jobsite.steer("js-nope-steer", "hi")
  end

  test "steer times out with a typed error and withdraws the pause request", %{
    repo: repo,
    log: log
  } do
    id = start_running!(repo, log)

    # a zero budget cannot be met: the executor cannot have exited yet
    assert {:error, :steer_timeout} = Jobsite.steer(id, "hurry", timeout_ms: 0)
    assert ForemanServer.Jobsite.Control.intent(id) == :none

    pid = Executor.pid_for(id)
    ref = Process.monitor(pid)
    :ok = Jobsite.cancel(id, "cleanup")
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000
  end
end
