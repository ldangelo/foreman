defmodule ForemanServer.Jobsite.ResumePromptTest do
  # `Jobsite.resume_async/2` must carry an operator `:prompt` all the way to the
  # resumed iteration's agent invocation ("Continue." when omitted), and refuse
  # a blank/oversize prompt before anything is resumed.
  #
  # Real git repo, real event store, real executor; the agent CLI is a shell
  # script that records the arguments (which carry the prompt) it was given.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Executor, Sandboxes}
  alias ForemanServer.ProjectionStore

  @recording_agent Path.join(__DIR__, "support/recording_agent.sh")

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    repo = tmp_repo!()
    log = Path.join(System.tmp_dir!(), "prompts-#{System.unique_integer([:positive])}.log")
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
    path = Path.join(System.tmp_dir!(), "jobsite-prompt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_o, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_o, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_o, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    path
  end

  # Starts a jobsite whose first agent invocation sleeps, pauses it, and returns
  # once its executor is gone (so it is resumable).
  defp start_paused!(repo, {_log, agent_bin}) do
    agent =
      Agents.pi("x",
        binary: agent_bin,
        env: %{
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
    pid = Executor.pid_for(id)
    ref = Process.monitor(pid)
    :ok = Jobsite.pause(id, "test pause")
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000
    id
  end

  defp await_event(type, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if (data[:jobsite_id] || data["jobsite_id"]) == id, do: :ok, else: await_event(type, id)

      {:projection_event, _other} ->
        await_event(type, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  defp invocations(log) do
    log |> File.read!() |> String.split("--invocation--\n", trim: true)
  end

  test "resume_async(prompt:) reaches the resumed iteration's agent invocation", %{
    repo: repo,
    log: log
  } do
    id = start_paused!(repo, log)

    assert {:ok, ^id} = Jobsite.resume_async(id, prompt: "use JWT")
    await_event("JobsiteCompleted", id)

    resumed = List.last(invocations(elem(log, 0)))
    assert resumed =~ "use JWT"
    refute resumed =~ "Continue."
  end

  test "an omitted prompt keeps the default continuation prompt", %{repo: repo, log: log} do
    id = start_paused!(repo, log)

    assert {:ok, ^id} = Jobsite.resume_async(id)
    await_event("JobsiteCompleted", id)

    assert List.last(invocations(elem(log, 0))) =~ "Continue."
  end

  test "blank, non-string and oversize prompts are rejected before any resume", %{
    repo: repo,
    log: log
  } do
    id = start_paused!(repo, log)
    before_count = length(invocations(elem(log, 0)))

    for bad <- ["", "   ", 42, String.duplicate("a", 8_001)] do
      assert {:error, %Error{code: :spec_option_invalid}} = Jobsite.resume_async(id, prompt: bad)
    end

    assert Executor.pid_for(id) == nil
    assert length(invocations(elem(log, 0))) == before_count
    assert Jobsite.get(id).status == "paused"

    # exactly at the bound is accepted
    assert {:ok, ^id} = Jobsite.resume_async(id, prompt: String.duplicate("a", 8_000))
    await_event("JobsiteCompleted", id)
  end
end
