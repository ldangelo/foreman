defmodule ForemanServer.Aggregates.WorkerTest do
  @moduledoc """
  TRD-011: Worker aggregate unit tests.

  Pins the typed-event contract end-to-end:

    * `handle_command/2` for `worker.record` validates the payload, enforces
      terminal-event rules, and produces an event spec the Tracker can
      append.
    * `apply_event/2` decodes via `EventCodec.decode!/2` and folds the
      typed struct into `%State{}`. Sequence advances monotonically.
    * Codec compliance: an event_type/value mismatch raises; missing
      `@enforce_keys` raises; unknown fields raise.

  The tests do NOT spin up the EventStore or an Actor — they exercise
  the pure aggregate behaviour (state fold + command validation) and
  the codec contract, which is the source of truth for replay.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Worker
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.WorkerHeartbeat
  alias ForemanServer.Events.WorkerStarted

  defp uuid, do: EventStore.UUID.uuid4()

  defp start_payload(worker_id, run_id, overrides \\ %{}) do
    Map.merge(
      %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        adapter: "ForemanServer.Overwatch.Adapters.HeartbeatWorker",
        prompt_path: "/tmp/prompt-#{worker_id}.md"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # handle_command/2 — worker.record
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — worker.record" do
    test "produces a WorkerStarted event spec for the canonical launch context" do
      worker_id = uuid()
      run_id = uuid()
      payload = start_payload(worker_id, run_id)

      assert {:ok, event_spec} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload |> Map.put(:event_type, "WorkerStarted") |> Map.put(:sequence, 0)
               })

      assert event_spec.event_type == "WorkerStarted"
      assert event_spec.stream_id == "worker:#{run_id}:#{worker_id}"
      assert event_spec.payload.worker_id == worker_id
      assert event_spec.payload.run_id == run_id
      assert event_spec.payload.session_id == payload.session_id
      assert event_spec.payload.adapter == payload.adapter
      assert event_spec.payload.prompt_path == payload.prompt_path
    end

    test "rejects an out-of-order sequence" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        event_type: "WorkerHeartbeat",
        sequence: 3
      }

      state = %Worker.State{
        exists?: true,
        worker_id: worker_id,
        run_id: run_id,
        status: "running",
        terminal?: false,
        last_sequence: 5
      }

      assert {:error, {:out_of_order_sequence, expected: 6, actual: 3}} =
               Worker.handle_command(state, %{
                 type: "worker.record",
                 payload: payload
               })
    end

    test "accepts the next expected sequence" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        event_type: "WorkerHeartbeat",
        sequence: 5
      }

      state = %Worker.State{
        exists?: true,
        worker_id: worker_id,
        run_id: run_id,
        status: "running",
        terminal?: false,
        last_sequence: 4
      }

      assert {:ok, _spec} =
               Worker.handle_command(state, %{
                 type: "worker.record",
                 payload: payload
               })
    end

    test "rejects non-terminal events on a terminal worker" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        event_type: "WorkerHeartbeat",
        sequence: 8
      }

      state = %Worker.State{
        exists?: true,
        worker_id: worker_id,
        run_id: run_id,
        status: "terminal",
        terminal?: true,
        last_sequence: 7
      }

      assert {:error, :worker_terminal} =
               Worker.handle_command(state, %{
                 type: "worker.record",
                 payload: payload
               })
    end

    test "rejects non-string run_id or worker_id" do
      assert {:error, {:missing_or_invalid, :run_id}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: %{
                   worker_id: uuid(),
                   event_type: "WorkerHeartbeat",
                   sequence: 0
                 }
               })

      assert {:error, {:missing_or_invalid, :worker_id}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: %{
                   run_id: uuid(),
                   event_type: "WorkerHeartbeat",
                   sequence: 0
                 }
               })
    end

    test "non-worker.record commands return :unhandled" do
      assert :unhandled = Worker.handle_command(Worker.initial_state(), %{type: "other", payload: %{}})
    end

    test "rejects WorkerStarted missing session_id with :malformed_event (replay-safety)" do
      worker_id = uuid()
      run_id = uuid()

      # All declared WorkerStarted fields except session_id.
      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        adapter: "A",
        prompt_path: "/p",
        event_type: "WorkerStarted",
        sequence: 0
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "missing enforced keys"
      assert msg =~ "session_id"
    end

    test "rejects WorkerStarted missing adapter with :malformed_event" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        prompt_path: "/p",
        event_type: "WorkerStarted",
        sequence: 0
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "missing enforced keys"
      assert msg =~ "adapter"
    end

    test "rejects WorkerStarted missing prompt_path with :malformed_event" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        adapter: "A",
        event_type: "WorkerStarted",
        sequence: 0
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "missing enforced keys"
      assert msg =~ "prompt_path"
    end

    test "rejects WorkerStarted with unknown fields with :malformed_event" do
      worker_id = uuid()
      run_id = uuid()

      payload = %{
        worker_id: worker_id,
        run_id: run_id,
        session_id: uuid(),
        adapter: "A",
        prompt_path: "/p",
        extraneous: "no",
        event_type: "WorkerStarted",
        sequence: 0
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "unknown fields"
    end

    test "rejects unknown event_type with :malformed_event" do
      payload = %{
        worker_id: uuid(),
        run_id: uuid(),
        event_type: "TotallyMadeUp",
        sequence: 0
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "unregistered event_type"
    end

    test "rejects WorkerHeartbeat with non-typed-event extras with :malformed_event" do
      payload = %{
        worker_id: uuid(),
        run_id: uuid(),
        event_type: "WorkerHeartbeat",
        sequence: 0,
        bogus: "extra"
      }

      assert {:error, {:malformed_event, msg}} =
               Worker.handle_command(Worker.initial_state(), %{
                 type: "worker.record",
                 payload: payload
               })

      assert msg =~ "unknown fields"
    end
  end

  # ---------------------------------------------------------------------------
  # apply_event/2 — typed event fold
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — typed event fold" do
    test "WorkerStarted stores the full launch context, sets status running, terminal? false" do
      worker_id = uuid()
      run_id = uuid()
      session_id = uuid()

      payload =
        start_payload(worker_id, run_id, %{
          session_id: session_id,
          tool_names: ["read_file", "grep"],
          artifact_paths: ["/tmp/a.txt"]
        })

      state =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(payload, :sequence, 0)
        })

      assert state.exists? == true
      assert state.worker_id == worker_id
      assert state.run_id == run_id
      assert state.session_id == session_id
      assert state.adapter == payload.adapter
      assert state.prompt_path == payload.prompt_path
      assert state.tool_names == ["read_file", "grep"]
      assert state.artifact_paths == ["/tmp/a.txt"]
      assert state.status == "running"
      assert state.terminal? == false
      assert state.last_sequence == 0
    end

    test "WorkerHeartbeat updates status, advances sequence" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        Worker.apply_event(state_after_started, %{
          event_type: "WorkerHeartbeat",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1, timestamp: 1_700_000_000_000}
        })

      assert state.last_sequence == 1
      assert state.status == "heartbeat"
    end

    test "WorkerUnresponsive is RECOVERABLE: terminal? stays false" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        Worker.apply_event(state_after_started, %{
          event_type: "WorkerUnresponsive",
          payload: %{
            worker_id: worker_id,
            run_id: run_id,
            sequence: 1,
            timeout_ms: 60_000
          }
        })

      assert state.terminal? == false, "WorkerUnresponsive must NOT set terminal?: true"
      assert state.status == "unresponsive"
      assert state.last_sequence == 1
    end

    test "after WorkerUnresponsive, a fresh WorkerStarted is allowed (recovery path)" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state_after_unresponsive =
        Worker.apply_event(state_after_started, %{
          event_type: "WorkerUnresponsive",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1}
        })

      # No error — allow_after_terminal must not reject WorkerStarted after Unresponsive.
      payload2 = start_payload(worker_id, run_id, %{session_id: uuid()})

      assert {:ok, _spec} =
               Worker.handle_command(state_after_unresponsive, %{
                 type: "worker.record",
                 payload: Map.put(payload2, :event_type, "WorkerStarted") |> Map.put(:sequence, 2)
               })
    end

    test "ToolCallFinished increments tool_events" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        Worker.apply_event(state_after_started, %{
          event_type: "ToolCallFinished",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1, tool_name: "grep"}
        })

      assert state.tool_events == 1
      assert state.status == "running"
    end

    test "AssistantMessage increments assistant_messages" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        Worker.apply_event(state_after_started, %{
          event_type: "AssistantMessage",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1, content: "hello"}
        })

      assert state.assistant_messages == 1
    end

    test "WorkerStdout and WorkerStderr do not increment counters" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        state_after_started
        |> Worker.apply_event(%{
          event_type: "WorkerStdout",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1, line: "out"}
        })
        |> Worker.apply_event(%{
          event_type: "WorkerStderr",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 2, line: "err"}
        })

      assert state.last_sequence == 2
      assert state.tool_events == 0
      assert state.assistant_messages == 0
    end

    test "WorkerExited is terminal: true" do
      worker_id = uuid()
      run_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      state =
        Worker.apply_event(state_after_started, %{
          event_type: "WorkerExited",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1, reason: "normal"}
        })

      assert state.terminal? == true
      assert state.status == "terminal"
    end

    test "RunCompleted and RunFailed set terminal? true" do
      run_id = uuid()
      worker_id = uuid()

      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })

      completed =
        Worker.apply_event(state_after_started, %{
          event_type: "RunCompleted",
          payload: %{run_id: run_id, sequence: 1, status: "completed"}
        })

      assert completed.terminal? == true
      assert completed.status == "terminal"

      failed =
        Worker.apply_event(state_after_started, %{
          event_type: "RunFailed",
          payload: %{run_id: run_id, sequence: 1, reason: "boom"}
        })

      assert failed.terminal? == true
      assert failed.status == "terminal"
    end

    test "sequence advances monotonically via bump_sequence/2" do
      worker_id = uuid()
      run_id = uuid()

      state =
        Worker.initial_state()
        |> Worker.apply_event(%{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(worker_id, run_id), :sequence, 0)
        })
        |> Worker.apply_event(%{
          event_type: "WorkerHeartbeat",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 1}
        })
        |> Worker.apply_event(%{
          event_type: "ToolCallFinished",
          payload: %{worker_id: worker_id, run_id: run_id, sequence: 2}
        })

      assert state.last_sequence == 2
    end
  end

  # ---------------------------------------------------------------------------
  # EventCodec contract for typed events
  # ---------------------------------------------------------------------------

  describe "EventCodec contract" do
    test "registered/0 returns all 10 typed event types" do
      expected =
        Enum.sort([
          "WorkerStarted",
          "WorkerHeartbeat",
          "WorkerUnresponsive",
          "WorkerExited",
          "WorkerStdout",
          "WorkerStderr",
          "ToolCallFinished",
          "AssistantMessage",
          "RunCompleted",
          "RunFailed"
        ])

      assert Enum.sort(EventCodec.registered()) == expected
    end

    test "decode!/2 round-trips a WorkerStarted plain map" do
      data = %{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        adapter: "A",
        prompt_path: "/p",
        tool_names: ["a"],
        artifact_paths: ["/x"],
        sequence: 0
      }

      assert %WorkerStarted{} = EventCodec.decode!("WorkerStarted", data)
    end

    test "decode!/2 raises when WorkerStarted is missing session_id" do
      data = %{
        worker_id: "w1",
        run_id: "r1",
        adapter: "A",
        prompt_path: "/p"
      }

      assert_raise ArgumentError, ~r/missing enforced keys.*:session_id/, fn ->
        EventCodec.decode!("WorkerStarted", data)
      end
    end

    test "decode!/2 raises when WorkerStarted is missing adapter" do
      data = %{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        prompt_path: "/p"
      }

      assert_raise ArgumentError, ~r/missing enforced keys.*:adapter/, fn ->
        EventCodec.decode!("WorkerStarted", data)
      end
    end

    test "decode!/2 raises when WorkerStarted is missing prompt_path" do
      data = %{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        adapter: "A"
      }

      assert_raise ArgumentError, ~r/missing enforced keys.*:prompt_path/, fn ->
        EventCodec.decode!("WorkerStarted", data)
      end
    end

    test "decode!/2 raises on unknown fields" do
      data = %{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        adapter: "A",
        prompt_path: "/p",
        extraneous: "no"
      }

      assert_raise ArgumentError, ~r/unknown fields.*:extraneous/, fn ->
        EventCodec.decode!("WorkerStarted", data)
      end
    end

    test "decode_recorded!/1 decodes from a RecordedEvent-shaped map" do
      data = %{worker_id: "w1", run_id: "r1", sequence: 0, timestamp: 1}

      assert %WorkerHeartbeat{} =
               EventCodec.decode_recorded!(%{event_type: "WorkerHeartbeat", data: data})
    end
  end

  # ---------------------------------------------------------------------------
  # next_sequence/1
  # ---------------------------------------------------------------------------

  describe "next_sequence/1" do
    test "returns 0 from initial_state (last_sequence: -1)" do
      assert Worker.next_sequence(Worker.initial_state()) == 0
    end

    test "advances as state evolves" do
      state_after_started =
        Worker.apply_event(Worker.initial_state(), %{
          event_type: "WorkerStarted",
          payload: Map.put(start_payload(uuid(), uuid()), :sequence, 0)
        })

      assert Worker.next_sequence(state_after_started) == 1
    end
  end
end
