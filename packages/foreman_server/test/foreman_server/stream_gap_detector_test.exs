defmodule ForemanServer.StreamGapDetectorTest do
  @moduledoc """
  TRD-041 / AC-021-3: codifies the StreamGapDetector behavior:
    * `StreamGapDetected` is emitted when projected count < actual version
    * further appends to the affected stream are blocked
    * `:resolve` clears the blocked bit and unblocks appends
    * the alert route flows through `CommandRouter.handle/1` (not direct
      `EventStore.append/1`) so the architecture invariant holds
    * the alert targets the dedicated `stream_gap_alerts` stream, NOT
      the affected stream, so the detector cannot self-deadlock when
      the alert route is consulted

  Note: the detector is a supervised child of `ForemanServer.Application`,
  so these tests start the full application to exercise the real wiring.
  """

  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, StreamGapDetector}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-stream-gap-test-#{System.unique_integer([:positive])}"
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

  test "check/1 returns :ok for an unknown stream" do
    assert :ok = StreamGapDetector.check("run:does-not-exist")
  end

  test "resolve/1 is idempotent on an unknown stream" do
    assert :ok = StreamGapDetector.resolve("run:does-not-exist")
  end

  test "stream_gap.detect appends a StreamGapDetected event to stream_gap_alerts" do
    affected_stream_id = "run:gap-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             CommandRouter.handle(%{
               command_id: "stream-gap-alert:test:#{affected_stream_id}",
               command_type: "stream_gap.detect",
               payload: %{
                 affected_stream_id: affected_stream_id,
                 projected_version: 2,
                 actual_version: 4
               }
             })

    event = Map.get(result, :event)
    assert event.event_type == "StreamGapDetected"
    assert event.stream_id == "stream_gap_alerts"
    assert event.payload.affected_stream_id == affected_stream_id
  end

  test "stream_gap.detect requires a binary affected_stream_id" do
    assert {:error, :affected_stream_id_required} =
             CommandRouter.handle(%{
               command_id: "stream-gap-alert:missing",
               command_type: "stream_gap.detect",
               payload: %{projected_version: 1, actual_version: 2}
             })

    assert {:error, :affected_stream_id_required} =
             CommandRouter.handle(%{
               command_id: "stream-gap-alert:empty",
               command_type: "stream_gap.detect",
               payload: %{affected_stream_id: "", projected_version: 1, actual_version: 2}
             })
  end

  test "stream_gap.detect is exempt from the pre-append gap check" do
    # The exemption is structural (command-type based) so it must hold
    # regardless of detector state.
    fresh_stream = "run:fresh-#{System.unique_integer([:positive])}"

    assert :ok = StreamGapDetector.check(fresh_stream)

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "stream-gap-alert:#{fresh_stream}",
               command_type: "stream_gap.detect",
               payload: %{
                 affected_stream_id: fresh_stream,
                 projected_version: 0,
                 actual_version: 1
               }
             })
  end

  test "CommandRouter.handle/1 returns :stream_gap when the affected stream is blocked" do
    project_id = "proj-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"
    run_stream = "run:#{run_id}"

    # Start a run through the router so projection and event store
    # both register one event on the run stream.
    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "test-#{run_id}",
               command_type: "run.start",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 phase_order: ["developer"],
                 workflow: "default"
               }
             })

    assert ProjectionStore.projected_stream_versions()[run_stream] == 1
    assert EventStore.stream_version(run_stream) == 1

    # Simulate silent projection loss: directly LOWER the per-stream
    # count in the projection so the next scan registers a gap. The
    # actual event store stays at version 1, but the projection
    # believes the stream has 0 events. The detector iterates over
    # `ProjectionStore.projected_stream_versions/0`, so the key MUST
    # remain in the map (with a divergent count) for the gap to be
    # detected.
    :sys.replace_state(ProjectionStore, fn projection ->
      versions = Map.get(projection, :projected_stream_versions, %{})
      Map.put(projection, :projected_stream_versions, Map.put(versions, run_stream, 0))
    end)

    assert ProjectionStore.projected_stream_versions()[run_stream] == 0
    assert EventStore.stream_version(run_stream) == 1

    # Drive a single scan synchronously. The detector is a GenServer,
    # so sending :scan and reading state with :sys.get_state forces
    # the scan to complete before we observe the result.
    send(Process.whereis(StreamGapDetector), :scan)
    _ = :sys.get_state(StreamGapDetector)

    # After the scan, the detector must mark the stream blocked.
    assert :blocked = StreamGapDetector.check(run_stream)

    # The detector also dispatches a `stream_gap.detect` command, so
    # the alerts stream should have one StreamGapDetected event.
    assert Enum.any?(
             EventStore.stream("stream_gap_alerts"),
             fn event ->
               event.event_type == "StreamGapDetected" and
                 event.payload.affected_stream_id == run_stream
             end
           )

    # An append targeting the SAME blocked stream is now refused.
    # `run.update` writes to the `run:<run_id>` stream, which is the
    # stream the detector just blocked.
    assert {:error, :stream_gap} =
             CommandRouter.handle(%{
               command_id: "post-gap-#{run_id}",
               command_type: "run.update",
               payload: %{run_id: run_id, status: "in_progress"}
             })

    # resolve/1 unblocks the stream and the next append succeeds.
    assert :ok = StreamGapDetector.resolve(run_stream)
    assert :ok = StreamGapDetector.check(run_stream)

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "post-resolve-#{run_id}",
               command_type: "run.update",
               payload: %{run_id: run_id, status: "in_progress"}
             })
  end

  test "scan does not block streams whose projection count matches actual version" do
    # Regression: a stream that is in sync (e.g. just started through
    # the router) must remain unblocked. The detector's scan must skip
    # any stream where EventStore.stream_version/1 equals the
    # projection's per-stream count.
    project_id = "proj-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "clean-#{run_id}",
               command_type: "run.start",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 phase_order: ["developer"],
                 workflow: "default"
               }
             })

    send(Process.whereis(StreamGapDetector), :scan)
    _ = :sys.get_state(StreamGapDetector)

    assert :ok = StreamGapDetector.check("run:#{run_id}")

    assert EventStore.stream_version("run:#{run_id}") ==
             ProjectionStore.projected_stream_versions()["run:#{run_id}"]
  end
end
