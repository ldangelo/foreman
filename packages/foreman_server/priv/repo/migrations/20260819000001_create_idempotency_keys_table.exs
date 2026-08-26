defmodule ForemanServer.Repo.Migrations.CreateIdempotencyKeysTable do
  @moduledoc """
  Creates the `idempotency_keys` table for durable invocation records
  with status {started, completed, ambiguous}.

  TRD-2026-4212be7e / RTE-T001 / TRD-075.
  Satisfies REQ-017 and REQ-026.
  """
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :key, :string, primary_key: true
      add :status, :string, null: false
      add :metadata, :map, default: %{}, null: false
      timestamps type: :utc_datetime_usec, updated_at: false
    end

    create index(:idempotency_keys, [:status])
    create index(:idempotency_keys, [:inserted_at])
  end
end
