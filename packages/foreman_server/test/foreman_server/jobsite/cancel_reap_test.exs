defmodule ForemanServer.Jobsite.CancelReapTest do
  @moduledoc """
  foreman-zmhzw. `thread stop` on a jobsite thread (`Threads.Actions.stop/3`, the jobsite door) is
  `Jobsite.cancel/2`: the agent is stopped through the harness, but the tool processes it started
  run in sessions of their own, so a signal to the agent's process group never reaches them and they
  outlived the cancelled jobsite, orphaned (ppid 1) in a worktree it was about to discard.

  Real jobsite, real git repo, real harness run of `fake_agent.sh` under erlexec, real tool process.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.StrayAgent
  alias ForemanServer.Threads.Actions

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)

    # The agent ignores SIGINT: after the cancel it keeps running until the harness escalates to
    # SIGTERM, which is the window the jobsite has to wait out before it can find its orphans.
    StrayAgent.tight_grace!(600)

    slot_init = "jobsite-cancel-reap-slot-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "jobsite-cancel-reap:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init, capacity: 100}
      })

    on_exit(fn ->
      CommandGateway.dispatch_system(%{
        type: "run_slots.release",
        command_id: "jobsite-cancel-reap:release:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init}
      })
    end)

    :ok
  end

  test "thread stop sweeps the tool process the cancelled agent started" do
    repo = tmp_repo!()
    id = start_running!(repo, :merge_to_head)
    worktree = Jobsite.get(id).worktree_path

    refute worktree == repo
    stray = StrayAgent.stray_pid!(worktree)
    agent = StrayAgent.ppid(stray)
    assert StrayAgent.alive?(agent)
    assert StrayAgent.alive?(stray)
    on_exit(fn -> StrayAgent.kill!(stray) end)

    assert {:ok, :stopping} = Actions.stop("jobsite:" <> id, "operator_stop")
    await_event("JobsiteCancelled", id)

    refute StrayAgent.alive?(agent)
    refute StrayAgent.alive?(stray), "the cancelled jobsite's tool process outlived it"
  end

  # A `:head` jobsite works in the caller's own checkout, where unrelated orphans can legitimately
  # live (a developer's tmux server started there, a daemon): sweeping it would kill them.
  test "thread stop never sweeps the caller's own checkout (:head)" do
    repo = tmp_repo!()
    bystander = StrayAgent.spawn_orphan!(repo)
    id = start_running!(repo, :head)
    stray = StrayAgent.stray_pid!(repo)
    on_exit(fn -> StrayAgent.kill!(stray) end)

    assert {:ok, :stopping} = Actions.stop("jobsite:" <> id, "operator_stop")
    await_event("JobsiteCancelled", id)

    assert StrayAgent.alive?(bystander)
  end

  # -- helpers ---------------------------------------------------------------

  defp tmp_repo! do
    path =
      Path.join(System.tmp_dir!(), "jobsite-cancel-reap-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    {_o, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_o, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_o, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_o, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp start_running!(repo, strategy) do
    agent =
      Agents.pi("x",
        binary: StrayAgent.fake_agent(),
        env: %{
          "FAKE_AGENT_STRAY_SECS" => "300",
          "FAKE_AGENT_IGNORE_INT" => "1",
          "FAKE_AGENT_SLEEP_ON_RUN" => "1",
          "FAKE_AGENT_SLEEP_SECS" => "300"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: strategy,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "go",
        max_iterations: 1,
        completion_signal: "NEVER"
      )

    await_event("JobsiteIterationStarted", id)
    id
  end

  defp await_event(type, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if (Map.get(data, :jobsite_id) || data["jobsite_id"]) == id,
          do: data,
          else: await_event(type, id)

      {:projection_event, _other} ->
        await_event(type, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end
end
