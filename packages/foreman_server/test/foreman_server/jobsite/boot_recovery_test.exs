defmodule ForemanServer.Jobsite.BootRecoveryTest do
  # The jobsite dispatch path is retired (docs/plans/retire-jobsites.md): a jobsite a restart left
  # non-terminal can never be resumed, so the boot closer records it as failed with `jobsite_retired`
  # (worktree and branch stay on disk). No mocks: the real event store and Jobsite aggregate, jobsites
  # seeded through real system commands; the one seam is `scan/1`'s injectable dispatcher, used only to
  # make individual jobsites fail.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, EventStore}
  alias ForemanServer.Jobsite.BootRecovery

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

    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id) != nil end)
  end

  # Worktree provisioned, sandbox up, iteration 1 open: what a restart mid-agent leaves, up to
  # the point where the agent reports its provider session.
  defp seed_iteration_open!(id) do
    seed_started!(id)

    dispatch!(id, "jobsite.worktree.provision", "wt", %{
      path: "/tmp/boot-recovery-no-such-worktree",
      branch: "jobsite/#{id}",
      base_sha: "abc123"
    })

    provision_sandbox!(id, "sb1")
    dispatch!(id, "jobsite.iteration.start", "it1", %{index: 1})
    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id)[:iteration_index] == 1 end)
  end

  # The same, after the agent reported its session and the executor recorded it
  # (`jobsite.session.bind`, while the iteration runs): an orphan a resume can continue.
  defp seed_running!(id) do
    seed_iteration_open!(id)
    dispatch!(id, "jobsite.session.bind", "s1", %{index: 1, session_id: "boot-recovery-session"})
    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id)[:session_id] == "boot-recovery-session" end)
  end

  defp provision_sandbox!(id, suffix) do
    dispatch!(id, "jobsite.sandbox.provision", suffix, %{
      provider: "host",
      sandbox_repo_path: "/tmp/boot-recovery-no-such-worktree",
      container_id: nil
    })

    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id)[:status] == "running" end)
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

  test "a running jobsite is failed as jobsite_retired, its worktree untouched" do
    id = unique_id("js-running")
    seed_running!(id)

    assert {:failed, ^id} = outcome_for(scan_outcomes!(), id)

    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id).status == "failed" end)
    assert "JobsiteFailed" in event_types(id)
    failed = events(id) |> Enum.find(&(&1.event_type == "JobsiteFailed"))
    assert field(failed.data, :code) == "jobsite_retired"
    assert ForemanServer.ProjectionStore.jobsite(id).worktree_path == "/tmp/boot-recovery-no-such-worktree"
  end

  test "a jobsite that never provisioned a worktree, and a paused one, are failed too" do
    started = unique_id("js-started")
    seed_started!(started)

    paused = unique_id("js-paused")
    seed_running!(paused)
    dispatch!(paused, "jobsite.pause", "p", %{reason: "server_restart", iteration_index: 0})
    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(paused).status == "paused" end)

    outcomes = scan_outcomes!()
    assert {:failed, ^started} = outcome_for(outcomes, started)
    assert {:failed, ^paused} = outcome_for(outcomes, paused)
  end

  test "terminal jobsites are untouched" do
    id = unique_id("js-terminal")
    seed_running!(id)
    dispatch!(id, "jobsite.complete", "done", %{iterations_run: 1})
    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id).status == "completed" end)
    types_before = event_types(id)

    assert outcome_for(scan_outcomes!(), id) == nil
    assert event_types(id) == types_before
  end

  test "an unreplayed (empty) projection does not hide an open jobsite from the closer" do
    id = unique_id("js-empty-projection")
    seed_running!(id)

    :sys.replace_state(ForemanServer.ProjectionStore, fn state -> %{state | jobsites: %{}} end)

    on_exit(fn ->
      ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    end)

    assert ForemanServer.ProjectionStore.list_jobsites() == []
    assert {:failed, ^id} = outcome_for(scan_outcomes!(), id)
    assert "JobsiteFailed" in event_types(id)
  end

  test "a second scan over the closed stream does nothing" do
    id = unique_id("js-twice")
    seed_running!(id)
    assert {:failed, ^id} = outcome_for(scan_outcomes!(), id)
    types = event_types(id)

    assert outcome_for(scan_outcomes!(), id) == nil
    assert event_types(id) == types
  end

  test "one jobsite failing to close is logged with its id and does not stop the others" do
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

    for n <- ~w(error raise exit) do
      assert {:error, _, %ForemanServer.Jobsite.Error{code: :boot_recovery_failed}} =
               outcome_for(outcomes, ids[n])

      assert log =~ "Jobsite boot recovery failed for #{ids[n]}"
      assert ForemanServer.ProjectionStore.jobsite(ids[n]).status == "running"
    end

    assert {:failed, _} = outcome_for(outcomes, ids["ok"])
  end

  test "the GenServer runs one scan at start and stops normally" do
    id = unique_id("js-genserver")
    seed_running!(id)

    {:ok, pid} = BootRecovery.start_link([])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

    wait_until(fn -> ForemanServer.ProjectionStore.jobsite(id).status == "failed" end)
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
