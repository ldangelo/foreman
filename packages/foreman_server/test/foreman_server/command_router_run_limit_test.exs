defmodule ForemanServer.CommandRouterRunLimitTest do
  use ExUnit.Case

  alias ForemanServer.{Aggregate, CommandRouter, EventStore, Operations, StreamGapDetector}
  alias ForemanServer.Aggregates.ProjectRunLimit

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-command-router-run-limit-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "concurrent starts reserve exactly 100 project slots" do
    project_id = unique_id("project")

    results =
      1..101
      |> Task.async_stream(
        fn index -> start_run(project_id, "run-#{index}") end,
        max_concurrency: 101,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 100
    assert Enum.count(results, fn r -> match?({:error, :run_limit_exceeded}, r) end) == 1

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert MapSet.size(state.active_run_ids) == 100

    assert Enum.count(EventStore.stream("project_run_limit:#{project_id}"), fn event ->
             event.event_type == "RunLimitRejected"
           end) == 1
  end

  test "duplicate start keeps the existing slot reserved" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} = start_run(project_id, run_id)
    assert {:ok, _} = start_run(project_id, run_id)
    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")

    assert state.active_run_ids == MapSet.new([run_id])
    assert Enum.count(EventStore.stream("run:#{run_id}")) == 1
  end

  test "canonical start failure compensates a fresh reservation" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunStarted",
               payload: %{run_id: run_id, project_id: project_id},
               metadata: %{}
             })

    assert {:ok, _} = start_run(project_id, run_id)

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert state.active_run_ids == MapSet.new([run_id])

    assert Enum.map(EventStore.stream("project_run_limit:#{project_id}"), & &1.event_type) == [
             "ProjectRunStarted"
           ]
  end

  test "missing project id resolves from the run projection" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunStarted",
               payload: %{run_id: run_id, project_id: project_id},
               metadata: %{}
             })

    assert Operations.Inspect.run_state(run_id).project_id == project_id

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: unique_id("command"),
               command_type: "run.start",
               payload: %{run_id: run_id}
             })

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert state.active_run_ids == MapSet.new([run_id])
  end

  # TRD-041 / AC-021-3, AC-022-1 — behavioral test for the slot-stream
  # gap-guard fix. Without `checked_slot_append/4` routing
  # `reserve_slot`/`release_slot` through `check_stream_gap/2`, a drift
  # on `project_run_limit:<project>` would silently bypass the
  # detector. This test forces the slot stream into the blocked set
  # and asserts the run.start saga rejects with `:stream_gap` — proving
  # the guard actually fires for slot appends.
  test "run.start rejects with :stream_gap when the project slot stream is blocked" do
    project_id = unique_id("project")
    run_id = unique_id("run")
    slot_stream = "project_run_limit:#{project_id}"

    # Block the slot stream by replacing the detector's blocked
    # set. This is the same surface a real drift would produce
    # after a scan, and it exercises the gap-check inside
    # `checked_slot_append/4`. A public `block/1` would let tests
    # mask production bugs by simulating drift out of band; using
    # `replace_state` keeps the guard's contract observable.
    pid = Process.whereis(StreamGapDetector)
    assert is_pid(pid)

    :sys.replace_state(pid, fn state ->
      %{state | blocked_streams: MapSet.put(state.blocked_streams, slot_stream)}
    end)

    assert {:error, :stream_gap} = start_run(project_id, run_id)

    # No slot was reserved (slot stream is still empty) and no run
    # stream was created — both appends were blocked at the gate.
    assert EventStore.stream(slot_stream) |> Enum.to_list() == []
    assert EventStore.stream("run:#{run_id}") |> Enum.to_list() == []

    # The ProjectRunLimit aggregate was never even consulted: the
    # guard fires before Aggregate.decide runs.
    {state, version} = Aggregate.load(ProjectRunLimit, slot_stream)
    assert state.active_run_ids == MapSet.new()
    assert version == 0

    # Cleanup: unblocking must let the next run.start through.
    assert :ok = StreamGapDetector.resolve(slot_stream)
    assert {:ok, _} = start_run(project_id, run_id)
  end

  # Best-effort invariant: a blocked slot stream does NOT prevent the
  # canonical run.<terminal> append (the run is already terminal in its
  # own stream — a missed slot release is a recoverable leak). It also
  # does NOT throw away the canonical emit when release_slot refuses:
  # the saga audits the slot-release failure and propagates `ok`.
  test "run.fail on a project with a blocked slot stream keeps the canonical run terminal and audits the slot release failure" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    # Reserve a slot normally first.
    assert {:ok, _} = start_run(project_id, run_id)
    slot_stream = "project_run_limit:#{project_id}"
    assert EventStore.stream_version(slot_stream) == 1

    # Block the slot stream by replacing the detector's blocked set.
    pid = Process.whereis(StreamGapDetector)
    assert is_pid(pid)

    :sys.replace_state(pid, fn state ->
      %{state | blocked_streams: MapSet.put(state.blocked_streams, slot_stream)}
    end)

    # run.fail still succeeds: the canonical RunFailed is written to
    # the run stream, and the slot-release refusal is audited (best
    # effort) so the saga propagates `ok` rather than failing the
    # terminal event.
    assert {:ok, _result} =
             CommandRouter.handle(%{
               command_id: unique_id("command"),
               command_type: "run.fail",
               payload: %{run_id: run_id, project_id: project_id, reason: "test"}
             })

    # The audit was gap-guarded too: writing any event onto a
    # drift-suspect slot stream would deepen the drift, so the
    # gap-guard swallows it. Operators must consult the run-stream
    # projection (the canonical record) for reconciliation.
    assert EventStore.stream_version("run:#{run_id}") == 2
    assert EventStore.stream_version(slot_stream) == 1

    refute Enum.any?(
             EventStore.stream(slot_stream),
             fn event -> event.event_type == "ProjectRunSlotReleaseFailed" end
           )

    assert :ok = StreamGapDetector.resolve(slot_stream)

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: unique_id("command"),
               command_type: "run.complete",
               payload: %{run_id: run_id, project_id: project_id}
             })

    assert EventStore.stream_version(slot_stream) == 2
  end

  defp start_run(project_id, run_id) do
    CommandRouter.handle(%{
      command_id: unique_id("command"),
      command_type: "run.start",
      payload: %{
        project_id: project_id,
        run_id: run_id,
        phase_order: ["developer"],
        workflow: "default"
      }
    })
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
