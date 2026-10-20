defmodule ForemanServer.Jobsite.BootRecoveryTest do
  # A jobsite whose executor died with the server (`:temporary` children are
  # never restarted) stays non-terminal forever. The boot scan must record it as
  # paused with reason "server_restart" -- never resume it -- so the existing
  # resume path picks it up.
  #
  # No mocks: the real event store, Jobsite aggregate/projection/executor, and
  # a real fake-agent process. Jobsites are orphaned by hard-killing their real
  # executor, or seeded through real system commands. The one seam is `scan/1`'s
  # injectable dispatcher, used only to make individual jobsites fail.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, EventStore, Jobsite}
  alias ForemanServer.Jobsite.{Agents, BootRecovery, Executor, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-bootrec-#{System.unique_integer([:positive])}")
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

  defp wait_until(fun, deadline_ms \\ 5_000) do
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

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp dispatch!(id, type, suffix, payload) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: type,
               command_id: "boot-recovery-test:#{id}:#{type}:#{suffix}",
               aggregate_id: "jobsite:#{id}",
               payload: Map.put(payload, :jobsite_id, id)
             })
  end

  # `jobsite.start` only: status "starting", no worktree.
  defp seed_started!(id) do
    dispatch!(id, "jobsite.start", "start", %{
      repo_path: "/tmp/boot-recovery-no-such-repo",
      strategy: "head",
      max_iterations: 3
    })

    wait_until(fn -> Jobsite.get(id) != nil end)
  end

  # Worktree provisioned, sandbox up, iteration 1 open: what a restart mid-agent leaves.
  defp seed_running!(id) do
    seed_started!(id)

    dispatch!(id, "jobsite.worktree.provision", "wt", %{
      path: "/tmp/boot-recovery-no-such-worktree",
      branch: "jobsite/#{id}",
      base_sha: "abc123"
    })

    provision_sandbox!(id, "sb1")
    dispatch!(id, "jobsite.iteration.start", "it1", %{index: 1})
    wait_until(fn -> Jobsite.get(id)[:iteration_index] == 1 end)
  end

  defp provision_sandbox!(id, suffix) do
    dispatch!(id, "jobsite.sandbox.provision", suffix, %{
      provider: "host",
      sandbox_repo_path: "/tmp/boot-recovery-no-such-worktree",
      container_id: nil
    })

    wait_until(fn -> Jobsite.get(id)[:status] == "running" end)
  end

  defp events(id) do
    {:ok, events} = EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999)
    events
  end

  defp event_types(id), do: Enum.map(events(id), & &1.event_type)

  defp field(data, key), do: Map.get(data, key) || Map.get(data, to_string(key))

  defp scan_outcomes!(dispatch \\ &CommandGateway.dispatch_system/1) do
    assert {:ok, outcomes} = BootRecovery.scan(dispatch)
    outcomes
  end

  defp outcome_for(outcomes, id) do
    Enum.find(outcomes, fn outcome -> elem(outcome, 1) == id end)
  end

  test "killed executor: scan pauses it as server_restart, and the existing resume path completes it" do
    repo = tmp_repo!()

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

    executor_pid = Executor.pid_for(id)
    ref = Process.monitor(executor_pid)
    Process.exit(executor_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^executor_pid, :killed}, 2_000
    wait_until(fn -> Executor.pid_for(id) == nil end)

    # The bug this scan fixes: nothing marks the orphan as interrupted.
    assert Jobsite.get(id).status == "running"

    assert {:paused, ^id} = outcome_for(scan_outcomes!(), id)

    wait_until(fn -> Jobsite.get(id).status == "paused" end)
    paused = Jobsite.get(id)
    assert paused.paused_reason == "server_restart"
    assert paused.terminal? == false

    pauses = Enum.filter(events(id), &(&1.event_type == "JobsitePaused"))
    assert [%{data: data}] = pauses
    assert field(data, :reason) == "server_restart"
    # Iteration 2 was open at the crash, so the last completed one is 1.
    assert field(data, :iteration_index) == 1

    # It was not resumed by the scan.
    assert Executor.pid_for(id) == nil

    # Second run over the unchanged stream is a no-op.
    version_before = length(events(id))
    assert {:skipped, ^id, :already_paused} = outcome_for(scan_outcomes!(), id)
    assert length(events(id)) == version_before

    # The existing resume path takes it from there, through the open iteration.
    assert {:ok, result} = Jobsite.resume(id)
    assert Enum.map(result.iterations, & &1.index) == [1, 2, 3]
    assert Enum.at(result.iterations, 1).status == :failed
    wait_until(fn -> Jobsite.get(id).status == "completed" end)
    refute Map.has_key?(Jobsite.get(id), :paused_reason)
  end

  test "a jobsite with a live executor is never touched" do
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
    version_before = length(events(id))

    assert {:skipped, ^id, :executor_live} = outcome_for(scan_outcomes!(), id)
    assert length(events(id)) == version_before
    assert Jobsite.get(id).status == "running"

    assert :ok = Jobsite.cancel(id, "test cleanup")
    wait_until(fn -> Jobsite.get(id).status == "cancelled" end, 15_000)
  end

  test "terminal jobsites are untouched" do
    id = unique_id("js-terminal")
    seed_running!(id)
    dispatch!(id, "jobsite.complete", "done", %{iterations_run: 1})
    wait_until(fn -> Jobsite.get(id).status == "completed" end)
    types_before = event_types(id)

    outcomes = scan_outcomes!()

    assert outcome_for(outcomes, id) == nil
    assert event_types(id) == types_before
  end

  test "an unreplayed (empty) projection does not hide an orphaned jobsite from the scan" do
    id = unique_id("js-empty-projection")
    seed_running!(id)

    # What `ProjectionStore.init/1` installs when its boot replay of the event
    # log fails: `initial_state()`, i.e. no jobsites at all.
    :sys.replace_state(ForemanServer.ProjectionStore, fn state -> %{state | jobsites: %{}} end)
    on_exit(fn -> ForemanServer.ProjectionStore.rebuild([]) end)
    assert ForemanServer.ProjectionStore.list_jobsites() == []

    assert {:paused, ^id} = outcome_for(scan_outcomes!(), id)
    assert "JobsitePaused" in event_types(id)
  end

  test "a jobsite orphaned again after a resume is paused again (new stream version, new command id)" do
    id = unique_id("js-twice")
    seed_running!(id)

    assert {:paused, ^id} = outcome_for(scan_outcomes!(), id)
    wait_until(fn -> Jobsite.get(id).status == "paused" end)
    assert {:skipped, ^id, :already_paused} = outcome_for(scan_outcomes!(), id)

    # A resume that got as far as re-provisioning the sandbox, then died with
    # the next server restart.
    provision_sandbox!(id, "sb2")
    assert Jobsite.get(id).status == "running"
    refute Map.has_key?(Jobsite.get(id), :paused_reason)

    assert {:paused, ^id} = outcome_for(scan_outcomes!(), id)
    wait_until(fn -> Jobsite.get(id).status == "paused" end)

    assert Enum.count(event_types(id), &(&1 == "JobsitePaused")) == 2
  end

  test "a jobsite whose worktree was never provisioned is failed, not left unresumable" do
    id = unique_id("js-no-worktree")
    seed_started!(id)
    assert Jobsite.get(id).status == "starting"

    assert {:failed, ^id} = outcome_for(scan_outcomes!(), id)
    wait_until(fn -> Jobsite.get(id).status == "failed" end)

    failed = Jobsite.get(id)
    assert failed.terminal? == true
    assert failed.last_error.code == "executor_lost"
    refute "JobsitePaused" in event_types(id)
  end

  test "one jobsite failing to reconcile is logged with its id and does not stop the others" do
    ids = for n <- ~w(error raise exit ok), into: %{}, do: {n, unique_id("js-iso-#{n}")}
    for {_n, id} <- ids, do: seed_running!(id)

    real = &CommandGateway.dispatch_system/1

    dispatch = fn %{aggregate_id: "jobsite:" <> id} = command ->
      cond do
        id == ids["error"] -> {:error, :rejected_by_test}
        id == ids["raise"] -> raise "boom from test"
        id == ids["exit"] -> exit(:router_down_in_test)
        true -> real.(command)
      end
    end

    log = capture_log(fn -> send(self(), {:outcomes, scan_outcomes!(dispatch)}) end)
    assert_received {:outcomes, outcomes}

    assert {:error, _, %ForemanServer.Jobsite.Error{code: :boot_recovery_failed}} =
             outcome_for(outcomes, ids["error"])

    assert {:error, _, %ForemanServer.Jobsite.Error{code: :boot_recovery_failed}} =
             outcome_for(outcomes, ids["raise"])

    assert {:error, _, %ForemanServer.Jobsite.Error{code: :boot_recovery_failed}} =
             outcome_for(outcomes, ids["exit"])

    assert {:paused, _} = outcome_for(outcomes, ids["ok"])

    for n <- ~w(error raise exit) do
      assert log =~ "Jobsite boot recovery failed for #{ids[n]}"
      assert Jobsite.get(ids[n]).status == "running"
    end

    wait_until(fn -> Jobsite.get(ids["ok"]).status == "paused" end)
  end

  test "the GenServer runs one scan at start and stops normally" do
    id = unique_id("js-genserver")
    seed_running!(id)

    {:ok, pid} = BootRecovery.start_link([])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

    wait_until(fn -> Jobsite.get(id).status == "paused" end)
    assert Jobsite.get(id).paused_reason == "server_restart"
  end

  test "Application builds the child only while :start_jobsite_boot_recovery? is not false" do
    key = :start_jobsite_boot_recovery?
    previous = Application.fetch_env!(:foreman_server, key)
    on_exit(fn -> Application.put_env(:foreman_server, key, previous) end)

    Application.put_env(:foreman_server, key, true)
    assert ForemanServer.Application.maybe_jobsite_boot_recovery_child() == [BootRecovery]

    Application.put_env(:foreman_server, key, false)
    assert ForemanServer.Application.maybe_jobsite_boot_recovery_child() == []
  end
end
