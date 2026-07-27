defmodule ForemanServer.EventCodecTest do
  use ExUnit.Case, async: true

  alias ForemanServer.EventCodec

  describe "typed struct pass-through" do
    test "RunStarted struct returned unchanged when event_type matches" do
      struct = %ForemanServer.Events.RunStarted{run_id: "run-abc", task_id: "task-xyz"}
      assert EventCodec.decode!("RunStarted", struct) == struct
    end

    test "RunCompleted struct returned unchanged when event_type matches" do
      struct = %ForemanServer.Events.RunCompleted{run_id: "run-abc"}
      assert EventCodec.decode!("RunCompleted", struct) == struct
    end

    test "PhaseStarted struct returned unchanged when event_type matches" do
      struct = %ForemanServer.Events.PhaseStarted{run_id: "run-abc", phase_id: "phase-1"}
      assert EventCodec.decode!("PhaseStarted", struct) == struct
    end

    test "WorkerStarted struct returned unchanged when event_type matches" do
      struct = %ForemanServer.Events.WorkerStarted{worker_id: "w-1", run_id: "run-abc"}
      assert EventCodec.decode!("WorkerStarted", struct) == struct
    end

    test "WorkerExited struct returned unchanged when event_type matches" do
      struct = %ForemanServer.Events.WorkerExited{worker_id: "w-1", run_id: "run-abc"}
      assert EventCodec.decode!("WorkerExited", struct) == struct
    end

    test "raises ArgumentError when struct module mismatches event_type (AC3)" do
      # A PhaseStarted struct presented with event_type "WorkerStarted" is a mismatch
      struct = %ForemanServer.Events.PhaseStarted{run_id: "run-abc", phase_id: "phase-1"}

      assert_raise ArgumentError,
                   ~r/struct module .*PhaseStarted.* does not match event_type.*WorkerStarted/s,
                   fn ->
                     EventCodec.decode!("WorkerStarted", struct)
                   end
    end
  end

  describe "legacy map decoder" do
    test "decodes run_started legacy map to typed struct" do
      map = %{"type" => "run_started", "run_id" => "run-abc", "task_id" => "task-xyz"}
      result = EventCodec.decode!("run_started", map)

      assert %ForemanServer.Events.RunStarted{} = result
      assert result.run_id == "run-abc"
      assert result.task_id == "task-xyz"
    end

    test "decodes run_started with missing optional field defaults to nil" do
      map = %{"type" => "run_started", "run_id" => "run-abc"}
      result = EventCodec.decode!("run_started", map)

      assert %ForemanServer.Events.RunStarted{} = result
      assert result.run_id == "run-abc"
      assert result.task_id == nil
    end

    test "decodes run_completed legacy map to typed struct" do
      map = %{"type" => "run_completed", "run_id" => "run-abc"}
      result = EventCodec.decode!("run_completed", map)

      assert %ForemanServer.Events.RunCompleted{} = result
      assert result.run_id == "run-abc"
    end

    test "decodes phase_started legacy map to typed struct" do
      map = %{"type" => "phase_started", "run_id" => "run-abc", "phase_id" => "phase-1"}
      result = EventCodec.decode!("phase_started", map)

      assert %ForemanServer.Events.PhaseStarted{} = result
      assert result.run_id == "run-abc"
      assert result.phase_id == "phase-1"
    end

    test "decodes worker_started legacy map to typed struct" do
      map = %{"type" => "worker_started", "run_id" => "run-abc", "worker_id" => "w-1"}
      result = EventCodec.decode!("worker_started", map)

      assert %ForemanServer.Events.WorkerStarted{} = result
      assert result.run_id == "run-abc"
      assert result.worker_id == "w-1"
    end

    test "raises KeyError for unknown field in legacy map" do
      map = %{"type" => "run_started", "run_id" => "run-abc", "unknown_field" => "bad"}

      assert_raise KeyError, ~r/unknown key "unknown_field"/, fn ->
        EventCodec.decode!("run_started", map)
      end
    end

    test "raises ArgumentError for legacy map missing type field" do
      map = %{"run_id" => "run-abc"}

      assert_raise ArgumentError, ~r/must have a "type" field/, fn ->
        EventCodec.decode!("run_started", map)
      end
    end

    test "raises ArgumentError for unknown event type string" do
      map = %{"type" => "unknown_event", "run_id" => "run-abc"}

      assert_raise ArgumentError, ~r/unknown event type string/, fn ->
        EventCodec.decode!("unknown_event", map)
      end
    end

    test "raises ArgumentError when inner type mismatches expected event_type" do
      # expected "run_completed" but inner "type" says "run_started"
      map = %{"type" => "run_started", "run_id" => "run-abc"}

      assert_raise ArgumentError,
                   ~r/inner "type" field "run_started" does not match expected event_type.*"run_completed"/s,
                   fn ->
                     EventCodec.decode!("run_completed", map)
                   end
    end

    test "raises ArgumentError when inner type mismatches expected event_type (CamelCase)" do
      # expected "RunCompleted" (CamelCase) vs inner "run_started" (snake_case)
      map = %{"type" => "run_started", "run_id" => "run-abc"}

      assert_raise ArgumentError,
                   ~r/inner "type" field "run_started" does not match expected event_type.*"RunCompleted"/s,
                   fn ->
                     EventCodec.decode!("RunCompleted", map)
                   end
    end

    test "raises ArgumentError when required field is missing (@enforce_keys activated)" do
      # RunStarted requires :run_id — omitting it should trigger struct!/2 enforcement
      map = %{"type" => "run_started", "task_id" => "task-xyz"}

      assert_raise ArgumentError,
                   ~r/must also be given.*:run_id/si,
                   fn ->
                     EventCodec.decode!("run_started", map)
                   end
    end

  end

  describe "versioned envelope" do
    test "v=1 envelope validates typed struct against event_type" do
      struct = %ForemanServer.Events.RunStarted{run_id: "run-abc", task_id: "task-xyz"}
      envelope = %{"v" => 1, "data" => struct}

      assert EventCodec.decode!("RunStarted", envelope) == struct
    end

    test "v=1 envelope raises ArgumentError on module mismatch" do
      struct = %ForemanServer.Events.PhaseStarted{run_id: "run-abc", phase_id: "phase-1"}
      envelope = %{"v" => 1, "data" => struct}

      assert_raise ArgumentError,
                   ~r/does not match event_type.*RunStarted/s,
                   fn ->
                     EventCodec.decode!("RunStarted", envelope)
                   end
    end

    test "v=0 envelope dispatches as legacy map using its own type field" do
      envelope = %{"v" => 0, "data" => %{"type" => "run_started", "run_id" => "run-abc"}}
      result = EventCodec.decode!("run_started", envelope)

      assert %ForemanServer.Events.RunStarted{} = result
      assert result.run_id == "run-abc"
    end

    test "v=0 envelope raises ArgumentError when inner type mismatches expected event_type" do
      # expected "run_completed" but inner data says "run_started"
      envelope = %{"v" => 0, "data" => %{"type" => "run_started", "run_id" => "run-abc"}}

      assert_raise ArgumentError,
                   ~r/inner "type" field "run_started" does not match expected event_type.*"run_completed"/s,
                   fn ->
                     EventCodec.decode!("run_completed", envelope)
                   end
    end
  end

  describe "map with __struct__" do
    test "decodes __struct__ map to typed struct when module matches event_type" do
      map = %{
        "__struct__" => "ForemanServer.Events.RunStarted",
        "run_id" => "run-abc",
        "task_id" => "task-xyz"
      }

      result = EventCodec.decode!("RunStarted", map)

      assert %ForemanServer.Events.RunStarted{} = result
      assert result.run_id == "run-abc"
      assert result.task_id == "task-xyz"
    end

    test "raises ArgumentError when __struct__ module mismatches event_type" do
      map = %{
        "__struct__" => "ForemanServer.Events.PhaseStarted",
        "run_id" => "run-abc",
        "phase_id" => "phase-1"
      }

      assert_raise ArgumentError,
                   ~r/does not match event_type.*RunStarted/s,
                   fn ->
                     EventCodec.decode!("RunStarted", map)
                   end
    end

    test "raises KeyError for unknown field in __struct__ map" do
      map = %{
        "__struct__" => "ForemanServer.Events.RunStarted",
        "run_id" => "run-abc",
        "bad_key" => "value"
      }

      assert_raise KeyError, ~r/unknown key "bad_key"/, fn ->
        EventCodec.decode!("RunStarted", map)
      end
    end
  end
end
