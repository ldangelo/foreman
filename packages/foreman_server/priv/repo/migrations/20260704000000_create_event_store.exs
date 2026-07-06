defmodule ForemanServer.Repo.Migrations.CreateEventStore do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:foreman_events, primary_key: false) do
      add :event_id, :text, primary_key: true
      add :stream_id, :text, null: false
      add :stream_version, :bigint, null: false
      add :event_type, :text, null: false
      add :schema_version, :integer, null: false
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :text, null: false
      add :causation_id, :text
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create_if_not_exists index(:foreman_events, [:stream_id, :stream_version], name: :foreman_events_stream_idx)
    create_if_not_exists index(:foreman_events, [:event_type, :occurred_at], name: :foreman_events_type_idx)
    create_if_not_exists index(:foreman_events, [:correlation_id], name: :foreman_events_correlation_idx)

    create_if_not_exists unique_index(:foreman_events, [:stream_id, :stream_version], name: :foreman_events_stream_version_idx)

    create_if_not_exists unique_index(
                           :foreman_events,
                           ["stream_id", "(metadata ->> 'idempotency_key')"],
                           name: :foreman_events_idempotency_idx,
                           where: "metadata ? 'idempotency_key'"
                         )

    create_if_not_exists table(:foreman_projection_checkpoints, primary_key: false) do
      add :projection_name, :text, primary_key: true
      add :last_event_id, references(:foreman_events, column: :event_id, type: :text)
      add :last_stream_version, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :rebuild_started_at, :utc_datetime_usec
    end
  end
end
