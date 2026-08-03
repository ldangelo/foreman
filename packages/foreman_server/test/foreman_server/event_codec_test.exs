defmodule ForemanServer.EventCodecTest do
  use ExUnit.Case, async: true

  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{
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
      wrong = %WorkerStarted{worker_id: "w1", run_id: "r1", session_id: "s1", adapter: "Ad", prompt_path: "/p"}

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

      assert %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7,
                               timestamp: nil} = result
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
    end
  end
end