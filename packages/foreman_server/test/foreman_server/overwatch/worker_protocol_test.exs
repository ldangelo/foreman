defmodule ForemanServer.Overwatch.WorkerProtocolTest do
  @moduledoc """
  TRD-011 / WorkerProtocol boundary tests.

  Pins the contract that every `WorkerProtocol.emit/2` variant routes
  through `Tracker` (the sole dispatch owner) and that no malformed
  typed event ever reaches the event log.

  Coverage:
    * `:worker_started` round-trips a WorkerStarted event with the full
      launch context (session_id, adapter, prompt_path).
    * `:worker_started` with a payload missing one of the codec-enforced
      fields is REJECTED at the command boundary (`{:malformed_event, _}`)
      and NO event is appended — proves the replay-poisoning prevention
      added to `Worker.handle_command/2`.
    * `:heartbeat` requires Tracker registration; produces a
      `WorkerHeartbeat` event with monotonically increasing sequence.
    * All six non-heartbeat variants route through `Tracker.dispatch_lifecycle/3`
      and append exactly one event to the worker stream.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.Overwatch.WorkerProtocol

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_tracker(opts \\ []) do
    start_supervised!({Tracker, opts}, id: :tracker)
  end

  defp spawn_worker do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp read_worker_events(worker_id, run_id) do
    Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  describe "emit(:worker_started, ...)" do
    test "round-trips a WorkerStarted event with the full launch context" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()
      session_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: session_id,
        adapter: "ForemanServer.Overwatch.Adapters.CliWorker",
        prompt_path: "/tmp/prompt-#{run_id}.md",
        tool_names: ["read", "write"],
        artifact_paths: ["/tmp/artifacts/#{run_id}"]
      }

      assert :ok = WorkerProtocol.emit(:worker_started, payload)

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerStarted") == 1
      [event] = events

      assert event.data["event_type"] == "WorkerStarted"
      assert event.data["worker_id"] == worker_id
      assert event.data["run_id"] == run_id
      assert event.data["session_id"] == session_id
      assert event.data["adapter"] == "ForemanServer.Overwatch.Adapters.CliWorker"
      assert event.data["prompt_path"] == "/tmp/prompt-#{run_id}.md"
      assert event.data["tool_names"] == ["read", "write"]
      assert event.data["artifact_paths"] == ["/tmp/artifacts/#{run_id}"]
    end

    test "rejects a payload missing session_id at the command boundary" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      bad_payload = %{
        worker_id: worker_id,
        run_id: run_id,
        adapter: "ForemanServer.Overwatch.Adapters.CliWorker",
        prompt_path: "/tmp/p.md"
        # session_id deliberately missing
      }

      assert {:error, {:malformed_event, msg}} =
               WorkerProtocol.emit(:worker_started, bad_payload)

      assert msg =~ "session_id"

      # Critical: NO event should have been appended to the worker stream.
      assert [] = read_worker_events(worker_id, run_id)
    end

    test "rejects a payload missing prompt_path at the command boundary" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      bad_payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        adapter: "A"
        # prompt_path deliberately missing
      }

      assert {:error, {:malformed_event, msg}} =
               WorkerProtocol.emit(:worker_started, bad_payload)

      assert msg =~ "prompt_path"
      assert [] = read_worker_events(worker_id, run_id)
    end

    test "rejects a payload missing adapter at the command boundary" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      bad_payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        prompt_path: "/p"
        # adapter deliberately missing
      }

      assert {:error, {:malformed_event, msg}} =
               WorkerProtocol.emit(:worker_started, bad_payload)

      assert msg =~ "adapter"
      assert [] = read_worker_events(worker_id, run_id)
    end
  end

  describe "emit(:heartbeat, ...)" do
    test "returns :not_registered for an unregistered worker and appends nothing" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      assert {:error, :not_registered} =
               WorkerProtocol.emit(:heartbeat, %{worker_id: worker_id, run_id: run_id})

      assert [] = read_worker_events(worker_id, run_id)
    end

    test "produces a WorkerHeartbeat event after registration" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()
      pid = spawn_worker()

      :ok = Tracker.register(worker_id, run_id, pid)

      assert {:ok, 0} =
               WorkerProtocol.emit(:heartbeat, %{worker_id: worker_id, run_id: run_id})

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerHeartbeat") == 1

      assert {:ok, 1} =
               WorkerProtocol.emit(:heartbeat, %{worker_id: worker_id, run_id: run_id})

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerHeartbeat") == 2
    end
  end

  describe "emit(:worker_exited, ...)" do
    test "appends a WorkerExited event for a registered worker" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()
      pid = spawn_worker()
      :ok = Tracker.register(worker_id, run_id, pid)

      assert :ok =
               WorkerProtocol.emit(:worker_exited, %{
                 worker_id: worker_id,
                 run_id: run_id
               })

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerExited") == 1
    end
  end

  describe "emit(:tool_call_finished, ...)" do
    test "appends a ToolCallFinished event" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      assert :ok =
               WorkerProtocol.emit(:tool_call_finished, %{
                 worker_id: worker_id,
                 run_id: run_id,
                 tool_name: "read",
                 result: %{"ok" => true}
               })

      events = read_worker_events(worker_id, run_id)
      assert count(events, "ToolCallFinished") == 1

      [event] = events
      assert event.data["tool_name"] == "read"
      assert event.data["result"] == %{"ok" => true}
    end
  end

  describe "emit(:assistant_message, ...)" do
    test "appends an AssistantMessage event" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      assert :ok =
               WorkerProtocol.emit(:assistant_message, %{
                 worker_id: worker_id,
                 run_id: run_id,
                 content: "hello world"
               })

      events = read_worker_events(worker_id, run_id)
      assert count(events, "AssistantMessage") == 1
      [event] = events
      assert event.data["content"] == "hello world"
    end
  end

  describe "emit(:worker_stdout, ...)" do
    test "appends a WorkerStdout event" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      assert :ok =
               WorkerProtocol.emit(:worker_stdout, %{
                 worker_id: worker_id,
                 run_id: run_id,
                 line: "hello"
               })

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerStdout") == 1
      [event] = events
      assert event.data["line"] == "hello"
    end
  end

  describe "emit(:worker_stderr, ...)" do
    test "appends a WorkerStderr event" do
      start_tracker()
      worker_id = uuid()
      run_id = uuid()

      assert :ok =
               WorkerProtocol.emit(:worker_stderr, %{
                 worker_id: worker_id,
                 run_id: run_id,
                 line: "boom"
               })

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerStderr") == 1
      [event] = events
      assert event.data["line"] == "boom"
    end
  end
end
