defmodule ForemanServer.EventCodecRunSlotsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.EventCodec

  describe "RunSlotAcquired" do
    setup do
      %{
        event_type: "RunSlotAcquired",
        data: %{
          "run_id" => "run-123",
          "capacity" => 4,
          "acquired_at_ms" => 1_723_154_809_000
        }
      }
    end

    test "encodes and decodes without data loss", %{event_type: type, data: data} do
      decoded = EventCodec.decode!(type, data)

      assert decoded.__struct__ == ForemanServer.Events.RunSlotAcquired
      assert decoded.run_id == "run-123"
      assert decoded.capacity == 4
      assert decoded.acquired_at_ms == 1_723_154_809_000
    end

    test "pass-through when already typed", %{event_type: type, data: data} do
      original = EventCodec.decode!(type, data)
      round_trip = EventCodec.decode!(type, original)

      assert round_trip == original
    end
  end

  describe "RunSlotQueued" do
    setup do
      %{
        event_type: "RunSlotQueued",
        data: %{
          "run_id" => "run-456",
          "position" => 2,
          "enqueued_at_ms" => 1_723_154_910_000
        }
      }
    end

    test "encodes and decodes without data loss", %{event_type: type, data: data} do
      decoded = EventCodec.decode!(type, data)

      assert decoded.__struct__ == ForemanServer.Events.RunSlotQueued
      assert decoded.run_id == "run-456"
      assert decoded.position == 2
      assert decoded.enqueued_at_ms == 1_723_154_910_000
    end

    test "pass-through when already typed", %{event_type: type, data: data} do
      original = EventCodec.decode!(type, data)
      round_trip = EventCodec.decode!(type, original)

      assert round_trip == original
    end
  end

  describe "RunSlotReleased" do
    setup do
      %{
        event_type: "RunSlotReleased",
        data: %{"run_id" => "run-789"}
      }
    end

    test "encodes and decodes without data loss", %{event_type: type, data: data} do
      decoded = EventCodec.decode!(type, data)

      assert decoded.__struct__ == ForemanServer.Events.RunSlotReleased
      assert decoded.run_id == "run-789"
    end

    test "pass-through when already typed", %{event_type: type, data: data} do
      original = EventCodec.decode!(type, data)
      round_trip = EventCodec.decode!(type, original)

      assert round_trip == original
    end
  end

  describe "RunSlotTransferred" do
    setup do
      %{
        event_type: "RunSlotTransferred",
        data: %{
          "released_run_id" => "run-old",
          "acquired_run_id" => "run-new",
          "acquired_at_ms" => 1_723_155_000_000
        }
      }
    end

    test "encodes and decodes without data loss", %{event_type: type, data: data} do
      decoded = EventCodec.decode!(type, data)

      assert decoded.__struct__ == ForemanServer.Events.RunSlotTransferred
      assert decoded.released_run_id == "run-old"
      assert decoded.acquired_run_id == "run-new"
      assert decoded.acquired_at_ms == 1_723_155_000_000
    end

    test "pass-through when already typed", %{event_type: type, data: data} do
      original = EventCodec.decode!(type, data)
      round_trip = EventCodec.decode!(type, original)

      assert round_trip == original
    end
  end

  describe "RunSlotWaiterRemoved" do
    setup do
      %{
        event_type: "RunSlotWaiterRemoved",
        data: %{"run_id" => "run-waiter"}
      }
    end

    test "encodes and decodes without data loss", %{event_type: type, data: data} do
      decoded = EventCodec.decode!(type, data)

      assert decoded.__struct__ == ForemanServer.Events.RunSlotWaiterRemoved
      assert decoded.run_id == "run-waiter"
    end

    test "pass-through when already typed", %{event_type: type, data: data} do
      original = EventCodec.decode!(type, data)
      round_trip = EventCodec.decode!(type, original)

      assert round_trip == original
    end
  end
end
