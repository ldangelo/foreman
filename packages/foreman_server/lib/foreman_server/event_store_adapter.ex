defmodule ForemanServer.EventStoreAdapter do
  @moduledoc """
  Local Commanded EventStore adapter that preserves `event_id` through the persistence layer.

  ## Problem
  The standard `Commanded.EventStore.EventData` has no `event_id` field.
  AC2 idempotency requires the deterministic `{aggregate_id, command_id}` → `event_id`
  to be persisted and retrieved. If we convert to `Commanded.EventStore.EventData{}`
  before append, the `event_id` is lost permanently.

  ## Solution
  This adapter takes a hybrid approach:
  - **Append** (`append_to_stream`): calls `ForemanServer.EventStore.append_to_stream`
    directly with the original `%EventStore.EventData{}` structs (which carry `event_id`),
    bypassing Commanded's `Mapper.to_event_data/1` conversion. This preserves `event_id`
    in the database while still being called through the Commanded application.
  - **Replay** (`stream_forward`): delegates directly to
    `Commanded.EventStore.Adapters.EventStore.stream_forward/4`. The underlying
    adapter returns `%RecordedEvent{}` with `event_id` populated directly from the
    database (since direct append preserved it). No metadata enrichment needed.

  All other adapter callbacks pass through directly to the Commanded adapter.
  """

  @behaviour Commanded.EventStore.Adapter

  @impl true
  def child_spec(application, config) do
    Commanded.EventStore.Adapters.EventStore.child_spec(application, config)
  end

  @impl true
  # Append directly to ForemanServer.EventStore, preserving event_id.
  # The events arrive as %EventStore.EventData{} from CommandRouter (which passes them
  # unchanged instead of converting to %Commanded.EventStore.EventData{}).
  # Calling the underlying event store directly bypasses Mapper.to_event_data/1,
  # keeping event_id intact in the database.
  def append_to_stream(_adapter_meta, stream_uuid, expected_version, events, opts \\ []) do
    opts = Keyword.put(opts, :name, ForemanServer.EventStore)
    ForemanServer.EventStore.append_to_stream(stream_uuid, expected_version, events, opts)
  end

  @impl true
  # Replay goes through the Commanded adapter path for consistency with subscriptions
  # and upcasting. The underlying adapter returns %RecordedEvent{} with event_id
  # populated directly from the database — direct append preserved it at top level.
  def stream_forward(adapter_meta, stream_uuid, start_version, read_batch_size) do
    Commanded.EventStore.Adapters.EventStore.stream_forward(
      adapter_meta,
      stream_uuid,
      start_version,
      read_batch_size
    )
  end

  @impl true
  def subscribe(adapter_meta, stream_uuid) do
    Commanded.EventStore.Adapters.EventStore.subscribe(adapter_meta, stream_uuid)
  end

  @impl true
  def subscribe_to(
        adapter_meta,
        stream_uuid,
        subscription_name,
        subscriber,
        start_from,
        opts \\ []
      ) do
    Commanded.EventStore.Adapters.EventStore.subscribe_to(
      adapter_meta,
      stream_uuid,
      subscription_name,
      subscriber,
      start_from,
      opts
    )
  end

  @impl true
  def ack_event(adapter_meta, subscriber, %Commanded.EventStore.RecordedEvent{} = event) do
    Commanded.EventStore.Adapters.EventStore.ack_event(adapter_meta, subscriber, event)
  end

  @impl true
  def unsubscribe(adapter_meta, subscription) do
    Commanded.EventStore.Adapters.EventStore.unsubscribe(adapter_meta, subscription)
  end

  @impl true
  def delete_subscription(adapter_meta, stream_uuid, subscription_name) do
    Commanded.EventStore.Adapters.EventStore.delete_subscription(
      adapter_meta,
      stream_uuid,
      subscription_name
    )
  end

  @impl true
  def read_snapshot(adapter_meta, source_uuid) do
    Commanded.EventStore.Adapters.EventStore.read_snapshot(adapter_meta, source_uuid)
  end

  @impl true
  def record_snapshot(adapter_meta, snapshot) do
    Commanded.EventStore.Adapters.EventStore.record_snapshot(adapter_meta, snapshot)
  end

  @impl true
  def delete_snapshot(adapter_meta, source_uuid) do
    Commanded.EventStore.Adapters.EventStore.delete_snapshot(adapter_meta, source_uuid)
  end
end
