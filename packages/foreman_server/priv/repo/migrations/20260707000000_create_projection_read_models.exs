defmodule ForemanServer.Repo.Migrations.CreateProjectionReadModels do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:foreman_project_projections, primary_key: false) do
      add(:project_id, :text, primary_key: true)
      add(:status, :text)
      add(:data, :map, null: false, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:last_event_id, references(:foreman_events, column: :event_id, type: :text))
    end

    create_if_not_exists table(:foreman_task_projections, primary_key: false) do
      add(:task_id, :text, primary_key: true)
      add(:project_id, :text)
      add(:status, :text)
      add(:data, :map, null: false, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:last_event_id, references(:foreman_events, column: :event_id, type: :text))
    end

    create_if_not_exists table(:foreman_run_projections, primary_key: false) do
      add(:run_id, :text, primary_key: true)
      add(:task_id, :text)
      add(:status, :text)
      add(:data, :map, null: false, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:last_event_id, references(:foreman_events, column: :event_id, type: :text))
    end

    create_if_not_exists table(:foreman_inbox_message_projections, primary_key: false) do
      add(:message_id, :text, primary_key: true)
      add(:run_id, :text)
      add(:task_id, :text)
      add(:project_id, :text)
      add(:data, :map, null: false, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:last_event_id, references(:foreman_events, column: :event_id, type: :text))
    end

    create_if_not_exists(
      index(:foreman_project_projections, [:status],
        name: :foreman_project_projections_status_idx
      )
    )

    create_if_not_exists(
      index(:foreman_task_projections, [:project_id, :status],
        name: :foreman_task_projections_project_status_idx
      )
    )

    create_if_not_exists(
      index(:foreman_run_projections, [:task_id, :status],
        name: :foreman_run_projections_task_status_idx
      )
    )

    create_if_not_exists(
      index(:foreman_inbox_message_projections, [:run_id],
        name: :foreman_inbox_message_projections_run_idx
      )
    )

    create_if_not_exists(
      index(:foreman_inbox_message_projections, [:project_id],
        name: :foreman_inbox_message_projections_project_idx
      )
    )
  end
end
