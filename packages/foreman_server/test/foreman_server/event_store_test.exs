defmodule ForemanServer.EventStoreTest do
  use ExUnit.Case, async: false

  defp event(number, id) do
    %EventStore.RecordedEvent{
      event_id: id,
      event_number: number,
      stream_uuid: "all",
      stream_version: number,
      correlation_id: nil,
      causation_id: nil,
      event_type: "Stub",
      data: "{}",
      metadata: "{}",
      created_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  test "returns event found in first page" do
    pages = [[event(1, "a"), event(2, "b"), event(3, "c")]]
    reader = stub_reader(pages)

    assert ForemanServer.EventStore.scan_forward("b", 0, [], reader) ==
             {:ok, event(2, "b")}
  end

  test "pages past 10,000 events (per for-3lel AC)" do
    pages =
      Enum.map(0..10, fn page_idx ->
        Enum.map(1..1_000, fn offset ->
          n = page_idx * 1_000 + offset
          event(n, "id-#{n}")
        end)
      end)

    reader = stub_reader(pages)

    assert ForemanServer.EventStore.scan_forward("id-10001", 0, [], reader) ==
             {:ok, event(10_001, "id-10001")}
  end

  test "returns event_not_found when target absent across all pages" do
    page1 = Enum.map(1..1000, fn n -> event(n, "id-#{n}") end)
    reader = stub_reader([page1, []])

    assert ForemanServer.EventStore.scan_forward("id-9999", 0, [], reader) ==
             {:error, :event_not_found}
  end

  test "read_event/2 returns event_not_found for non-binary input" do
    assert ForemanServer.EventStore.read_event(nil, []) ==
             {:error, :event_not_found}

    assert ForemanServer.EventStore.read_event(:nope, []) ==
             {:error, :event_not_found}
  end

  defp stub_reader(pages) do
    {:ok, agent} = Agent.start_link(fn -> :queue.from_list(pages) end)

    fn start_version, _count, _opts ->
      send(self(), {:read_pages_called, start_version})

      Agent.get_and_update(agent, fn
        queue ->
          case :queue.out(queue) do
            {{:value, page}, queue} -> {{:ok, page}, queue}
            {:empty, queue} -> {{:ok, []}, queue}
          end
      end)
    end
  end
end