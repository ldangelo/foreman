defmodule ForemanServer.Idempotency.IdempotencyKey do
  @moduledoc """
  Ecto schema for durable idempotency key records.
  Each record tracks a `{workflow}-{taskId}-{step}` key with status
  {started, completed, ambiguous} and associated metadata.

  TRD-2026-4212be7e / RTE-T001 / TRD-075.
  Extends the TRD-014 idempotency key contract (REQ-017, REQ-026).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @statuses [:started, :completed, :ambiguous]

  schema "idempotency_keys" do
    field :status, Ecto.Enum, values: @statuses
    field :metadata, :map, default: %{}
    timestamps type: :utc_datetime_usec, updated_at: false
  end

  @type t :: %__MODULE__{
          key: String.t(),
          status: :started | :completed | :ambiguous,
          metadata: map(),
          inserted_at: DateTime.t()
        }

  @doc "Build a changeset for upserting (insert or update-on-conflict) a record."
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:key, :status, :metadata])
    |> validate_required([:key, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Build a changeset for an upsert.  Pass conflict_target: :key and on_conflict at the Repo.insert call site."
  def upsert_changeset(record, attrs) do
    record
    |> cast(attrs, [:key, :status, :metadata])
    |> validate_required([:key, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
