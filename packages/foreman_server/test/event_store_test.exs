defmodule ForemanServer.EventStoreTest do
  use ExUnit.Case

  alias ForemanServer.{Event, EventCodec, EventStore, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-event-store-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    event_log_path = Path.join(tmp_dir, "events.term.log")

    Application.stop(:foreman_server)
    Application.delete_env(:foreman_server, :project_store_path)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, event_log_path: event_log_path}
  end

  test "Postgres schema contract defines envelope uniqueness and projection checkpoints" do
    schema = File.read!("priv/repo/migrations/001_create_event_store.sql")

    for column <- [
          "event_id",
          "stream_id",
          "stream_version",
          "event_type",
          "schema_version",
          "payload",
          "metadata",
          "occurred_at",
          "correlation_id",
          "causation_id"
        ] do
      assert schema =~ column
    end

    assert schema =~ "UNIQUE (stream_id, stream_version)"
    assert schema =~ "foreman_events_idempotency_idx"
    assert schema =~ "foreman_projection_checkpoints"
  end

  test "append persists event before projection updates and rebuilds projection from scratch" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, %Event{} = event} =
             EventStore.append(%{
               stream_id: "task:task-1",
               expected_stream_version: 0,
               event_type: "CommandAccepted",
               payload: %{command_id: "cmd-1", command_type: "task.create", status: "accepted"},
               metadata: %{idempotency_key: "cmd-1", correlation_id: "corr-1"}
             })

    assert event.stream_version == 1
    assert File.exists?(Application.fetch_env!(:foreman_server, :event_log_path))
    assert ProjectionStore.snapshot().commands["cmd-1"].status == "accepted"

    Application.stop(:foreman_server)
    assert :ok = Application.start(:foreman_server)

    assert ProjectionStore.snapshot().commands["cmd-1"].command_type == "task.create"
  end

  test "append rejects stale expected versions and duplicate idempotency keys" do
    assert :ok = Application.start(:foreman_server)

    input = %{
      stream_id: "run:run-1",
      expected_stream_version: 0,
      event_type: "RunStarted",
      payload: %{run_id: "run-1"},
      metadata: %{idempotency_key: "run-start"}
    }

    assert {:ok, %Event{stream_version: 1}} = EventStore.append(input)

    assert {:error, {:conflict, expected: 0, actual: 1}} =
             EventStore.append(%{input | metadata: %{}})

    assert {:error, {:duplicate_idempotency_key, "run-start"}} =
             EventStore.append(%{input | expected_stream_version: 1})
  end

  test "versioned decoder reads current and legacy event envelopes" do
    assert {:ok, event} =
             Event.new(
               %{
                 stream_id: "phase:phase-1",
                 event_type: "PhaseStarted",
                 payload: %{phase_id: "phase-1"},
                 metadata: %{correlation_id: "corr-1"}
               },
               1
             )

    assert {:ok, ^event} = event |> EventCodec.encode() |> EventCodec.decode()

    legacy = %{type: "CommandAccepted", payload: %{command_id: "legacy-cmd"}, sequence: 7}
    encoded_legacy = legacy |> :erlang.term_to_binary() |> Base.encode64()

    assert {:ok, %Event{event_type: "CommandAccepted", schema_version: 1, stream_version: 7}} =
             EventCodec.decode(encoded_legacy)

    assert {:error, {:unsupported_event_schema_version, 999}} =
             EventCodec.decode(%{schema_version: 999})
  end
end
