defmodule ForemanServer.EventCodecTest do
  use ExUnit.Case, async: true

  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    ProjectRunReservationReleased,
    ProjectRunReserved,
    RunBlocked,
    RunCancelled,
    RunCompleted,
    RunFailed,
    RunFlaggedStuck,
    RunPaused,
    WorkerHeartbeat,
    WorkerStarted,
    WorkerUnresponsive,
    WorkerExited
  }

  describe "decode!/2 pass-through" do
    test "returns struct as-is when __struct__ matches the registered module" do
      struct = %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7}
      assert EventCodec.decode!("WorkerHeartbeat", struct) == struct
    end
  end

  describe "decode!/2 mismatch" do
    test "raises ArgumentError when input has a different struct" do
      wrong = %WorkerStarted{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        adapter: "Ad",
        prompt_path: "/p"
      }

      assert_raise ArgumentError, ~r/EventCodec mismatch/, fn ->
        EventCodec.decode!("WorkerHeartbeat", wrong)
      end
    end
  end

  describe "decode!/2 plain map" do
    test "builds struct from atom-keyed map and preserves declared defaults" do
      result =
        EventCodec.decode!("WorkerHeartbeat", %{
          worker_id: "w1",
          run_id: "r1",
          sequence: 7
        })

      assert %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7, timestamp: nil} = result
    end

    test "builds struct from string-keyed map" do
      result =
        EventCodec.decode!("WorkerHeartbeat", %{
          "worker_id" => "w1",
          "run_id" => "r1",
          "sequence" => 7
        })

      assert result == %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7}
    end

    test "rejects duplicate atom/string forms of the same field" do
      assert_raise ArgumentError, ~r/both atom and string/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{
          "worker_id" => "w1",
          worker_id: "w-other"
        })
      end
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{
          worker_id: "w1",
          run_id: "r1",
          bogus_field: "x"
        })
      end
    end

    test "raises on missing enforced keys" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{run_id: "r1"})
      end
    end

    test "allows optional fields to be absent (defaults preserved)" do
      result = EventCodec.decode!("WorkerExited", %{worker_id: "w1"})
      assert %WorkerExited{worker_id: "w1", run_id: nil} = result
    end
  end

  describe "decode!/2 terminal run events" do
    test "builds typed terminal events and preserves project_id" do
      assert EventCodec.decode!("RunCompleted", %{run_id: "r1", project_id: "p1", sequence: 7}) ==
               %RunCompleted{run_id: "r1", project_id: "p1", sequence: 7}

      assert EventCodec.decode!("RunFailed", %{
               "run_id" => "r1",
               "project_id" => "p1",
               "sequence" => 8,
               "reason" => "worker_crashed"
             }) ==
               %RunFailed{
                 run_id: "r1",
                 project_id: "p1",
                 sequence: 8,
                 reason: "worker_crashed"
               }

      assert EventCodec.decode!("RunCancelled", %{
               run_id: "r1",
               project_id: "p1",
               reason: "operator_abort",
               sequence: 9
             }) ==
               %RunCancelled{
                 run_id: "r1",
                 project_id: "p1",
                 reason: "operator_abort",
                 sequence: 9
               }

      assert EventCodec.decode!("RunBlocked", %{
               run_id: "r1",
               project_id: "p1",
               reason: "awaiting_review",
               status: "blocked"
             }) ==
               %RunBlocked{
                 run_id: "r1",
                 project_id: "p1",
                 reason: "awaiting_review",
                 status: "blocked"
               }

      assert EventCodec.decode!("RunFlaggedStuck", %{
               run_id: "r1",
               project_id: "p1",
               flagged_at: 1_234
             }) ==
               %RunFlaggedStuck{run_id: "r1", project_id: "p1", flagged_at: 1_234}
    end

    test "rejects terminal run events that omit project_id" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunCompleted", %{run_id: "r1", sequence: 1})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunFailed", %{run_id: "r1", sequence: 1})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunCancelled", %{run_id: "r1", reason: "operator_abort"})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunBlocked", %{run_id: "r1", reason: "awaiting_review"})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunFlaggedStuck", %{run_id: "r1", flagged_at: 1_234})
      end
    end
  end

  describe "decode!/2 paused run events" do
    test "builds typed paused events and preserves defaults" do
      assert EventCodec.decode!("RunPaused", %{
               run_id: "r1",
               sequence: 10,
               reason: "operator_intervention"
             }) ==
               %RunPaused{
                 run_id: "r1",
                 sequence: 10,
                 reason: "operator_intervention",
                 metadata: %{}
               }
    end

    test "rejects paused events that omit run_id" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunPaused", %{reason: "operator_intervention"})
      end
    end
  end

  describe "decode!/2 project run reservation events" do
    test "builds typed reservation events and preserves retry payloads" do
      assert EventCodec.decode!("ProjectRunReserved", %{
               project_id: "p1",
               run_id: "r1",
               sequence: 1,
               command_id: "cmd-1",
               run_start_payload: %{task_id: "t1", workflow_snapshot: %{phases: []}}
             }) ==
               %ProjectRunReserved{
                 project_id: "p1",
                 run_id: "r1",
                 sequence: 1,
                 command_id: "cmd-1",
                 run_start_payload: %{task_id: "t1", workflow_snapshot: %{phases: []}}
               }

      assert EventCodec.decode!("ProjectRunReservationReleased", %{
               "project_id" => "p1",
               "run_id" => "r1",
               "sequence" => 2,
               "reason" => "terminal_event"
             }) ==
               %ProjectRunReservationReleased{
                 project_id: "p1",
                 run_id: "r1",
                 sequence: 2,
                 reason: "terminal_event"
               }
    end

    test "rejects reservation events that omit enforced keys" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("ProjectRunReserved", %{
          project_id: "p1",
          run_id: "r1",
          sequence: 1,
          command_id: "cmd-1"
        })
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("ProjectRunReservationReleased", %{project_id: "p1", run_id: "r1"})
      end
    end
  end

  describe "decode!/2 unregistered event_type" do
    test "raises ArgumentError when event_type is not registered" do
      assert_raise ArgumentError, ~r/unregistered event_type/, fn ->
        EventCodec.decode!("NotAType", %{worker_id: "w1", run_id: "r1"})
      end
    end
  end

  describe "decode!/2 argument validation" do
    test "raises when event_type is not a binary" do
      assert_raise ArgumentError, ~r/expects \(binary, map\)/, fn ->
        EventCodec.decode!(:not_a_string, %{worker_id: "w1"})
      end
    end
  end

  describe "decode_recorded!/1" do
    test "decodes a RecordedEvent-shaped map" do
      recorded = %{event_type: "WorkerUnresponsive", data: %{worker_id: "w1", run_id: "r1"}}

      assert EventCodec.decode_recorded!(recorded) ==
               %WorkerUnresponsive{worker_id: "w1", run_id: "r1"}
    end
  end

  describe "registered/0" do
    test "lists every registered event type" do
      assert "WorkerStarted" in EventCodec.registered()
      assert "WorkerHeartbeat" in EventCodec.registered()
      assert "WorkerUnresponsive" in EventCodec.registered()
      assert "WorkerExited" in EventCodec.registered()
      assert "ProjectRunReserved" in EventCodec.registered()
      assert "ProjectRunReservationReleased" in EventCodec.registered()
      assert "RunCompleted" in EventCodec.registered()
      assert "RunFailed" in EventCodec.registered()
      assert "RunCancelled" in EventCodec.registered()
      assert "RunBlocked" in EventCodec.registered()
      assert "RunFlaggedStuck" in EventCodec.registered()
      assert "RunPaused" in EventCodec.registered()
    end
  end
end
