defmodule ForemanServer.ProjectionStoreTimeoutTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Event
  alias ForemanServer.ProjectionStore

  setup do
    original_env = System.get_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
    original_app = Application.get_env(:foreman_server, :projection_rebuild_timeout_ms)

    on_exit(fn ->
      if is_nil(original_env) do
        System.delete_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
      else
        System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", original_env)
      end

      if is_nil(original_app) do
        Application.delete_env(:foreman_server, :projection_rebuild_timeout_ms)
      else
        Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, original_app)
      end
    end)

    :ok
  end

  # Construct events directly in memory (bypassing the EventStore GenServer
  # so the test doesn't depend on its append performance). 100K events at
  # the observed per-event cost (~1us in-memory reduce) reliably exceeds a
  # 1 ms Task.yield timeout on any reasonable test host.
  defp build_events(n) do
    now = DateTime.utc_now()

    for i <- 1..n do
      %Event{
        event_id: "ev-#{i}",
        stream_id: "stream-#{i}",
        stream_version: 1,
        event_type: "TaskCreated",
        schema_version: 1,
        payload: %{task_id: "t-#{i}", title: "T#{i}"},
        metadata: %{},
        occurred_at: now,
        correlation_id: nil,
        causation_id: nil
      }
    end
  end

  test "rebuild/2 returns :rebuild_timeout tuple (not GenServer.call exit) when internal deadline fires" do
    System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "1")
    Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 1)

    events = build_events(100_000)

    # With 1 ms internal Task.yield timeout and 100K events, the in-memory
    # reduce reliably exceeds 1 ms. The outer GenServer.call gets the same
    # timeout + 1_000 ms cushion (via with_timeout_cushion/1), so the
    # handler's nil branch fires first and returns {:error, :rebuild_timeout}
    # before the outer call times out.
    assert {:error, :rebuild_timeout} = ProjectionStore.rebuild(events, 1)
  end

  test "rebuild/1 wrapper uses finite timeout (not :infinity)" do
    System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "1")
    Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 1)

    events = build_events(100_000)

    # rebuild/1 delegates to rebuild/2 with the helper-provided timeout.
    assert {:error, :rebuild_timeout} = ProjectionStore.rebuild(events)
  end
end
