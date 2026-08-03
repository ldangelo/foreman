defmodule ForemanServer.Inbox.AttachBridgeAdapterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Inbox.{AttachBridgeAdapter, InboxItemStarted, SharedInbox}

  defmodule FakeSource do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    def correlation_id(%{"correlation_id" => id}), do: id
    def correlation_id(%{correlation_id: id}), do: id
  end

  defmodule MissingSource do
    def some_other(x), do: x
  end

  describe "normalize/1" do
    test "returns an InboxItemStarted struct" do
      item = AttachBridgeAdapter.normalize(%{"correlation_id" => "evt-1"})
      assert %InboxItemStarted{} = item
      assert item.correlation_id == "evt-1"
      assert is_integer(item.timestamp)
    end

    test "preserves streaming metadata under :metadata" do
      payload = %{
        "correlation_id" => "evt-2",
        "stream_id" => "stream-abc",
        "connection_id" => "conn-1",
        "connection_lifecycle" => "open",
        "extra" => "preserved"
      }

      item = AttachBridgeAdapter.normalize(payload)
      assert get_in(item.payload, [:metadata, "stream_id"]) == "stream-abc"
      assert get_in(item.payload, [:metadata, "connection_id"]) == "conn-1"
      assert get_in(item.payload, [:metadata, "connection_lifecycle"]) == "open"
      assert item.payload["extra"] == "preserved"
    end

    test "no streaming metadata means :metadata key is dropped" do
      payload = %{"correlation_id" => "evt-3"}
      item = AttachBridgeAdapter.normalize(payload)
      refute Map.has_key?(item.payload, :metadata)
    end

    test "handles atom-keyed payloads" do
      payload = %{correlation_id: "evt-atom", stream_id: "s1"}
      item = AttachBridgeAdapter.normalize(payload)
      assert item.correlation_id == "evt-atom"
      assert get_in(item.payload, [:metadata, :stream_id]) == "s1"
    end

    test "missing correlation id yields empty string" do
      item = AttachBridgeAdapter.normalize(%{"no_id" => true})
      assert item.correlation_id == ""
    end
  end

  describe "ingest/2" do
    test "routes through SharedInbox and returns :started for new item" do
      id = "ab-#{System.unique_integer([:positive])}"

      assert {:ok, :started, %InboxItemStarted{} = item} =
               AttachBridgeAdapter.ingest(FakeSource, %{"correlation_id" => id})

      assert item.correlation_id == id
    end

    test "dedupes second ingest with same correlation id" do
      id = "ab-dedup-#{System.unique_integer([:positive])}"
      assert {:ok, :started, _} = AttachBridgeAdapter.ingest(FakeSource, %{"correlation_id" => id})
      assert {:ok, :deduped, _} = AttachBridgeAdapter.ingest(FakeSource, %{"correlation_id" => id})
    end

    test "rejects sources that don't implement InboxItemCorrelationId" do
      assert {:error, {:unknown_source, MissingSource}} =
               AttachBridgeAdapter.ingest(MissingSource, %{"correlation_id" => "x"})
    end
  end
end
