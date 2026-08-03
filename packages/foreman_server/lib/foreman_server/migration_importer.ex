defmodule ForemanServer.MigrationImporter do
  @moduledoc """
  TRD-014: Migration importer that dispatches `ImportMigration` commands
  through `CommandRouter.dispatch/2`.

  Each migration record becomes a `migration.import.start`,
  `migration.record.import`, or `migration.import.complete` command
  keyed by `aggregate_id: "migration:<import_id>"`. All mutations
  flow through the existing event store; this module is a thin
  orchestrator over the canonical command path.
  """

  alias ForemanServer.CommandRouter

  @type import_id :: String.t()
  @type record :: map()

  @doc """
  Start a new migration import batch.

  Required fields on `batch`:
    * `:import_id` — stable unique id (also used as aggregate_id)
    * `:source` — string identifier of the upstream migration source
    * any additional metadata fields are preserved in the command payload
  """
  @spec start_import(map()) :: {:ok, map()} | {:error, term()}
  def start_import(batch) when is_map(batch) do
    import_id = require_field!(batch, :import_id)

    CommandRouter.dispatch(%{
      type: "migration.import.start",
      aggregate_id: "migration:#{import_id}",
      payload: batch
    })
  end

  @doc """
  Import a single record into an existing batch.

  Required fields on `record`:
    * `:import_id` — must match an existing batch
    * `:record_id` — stable id for the record (used for idempotency)
  """
  @spec import_record(map()) :: {:ok, map()} | {:error, term()}
  def import_record(record) when is_map(record) do
    import_id = require_field!(record, :import_id)
    _ = require_field!(record, :record_id)

    CommandRouter.dispatch(%{
      type: "migration.record.import",
      aggregate_id: "migration:#{import_id}",
      payload: record
    })
  end

  @doc """
  Mark a batch as completed.
  """
  @spec complete_import(map()) :: {:ok, map()} | {:error, term()}
  def complete_import(batch) when is_map(batch) do
    import_id = require_field!(batch, :import_id)

    CommandRouter.dispatch(%{
      type: "migration.import.complete",
      aggregate_id: "migration:#{import_id}",
      payload: batch
    })
  end

  @doc """
  Process a stream of records: start the batch, dispatch each record,
  then complete the batch. Returns a per-record result list.

  Useful for offline migration runs that read a file or stream.
  """
  @spec process(map()) :: {:ok, [term()]} | {:error, term()}
  def process(%{records: records} = batch) when is_list(records) do
    with {:ok, _} <- start_import(batch),
         results <-
           Enum.map(records, fn record ->
             import_id = Map.get(batch, :import_id)
             record_with_id = Map.put(record, :import_id, import_id)
             import_record(record_with_id)
           end),
         {:ok, _} <- complete_import(batch) do
      {:ok, results}
    end
  end

  def process(_), do: {:error, :missing_records}

  # -- private helpers ------------------------------------------------------

  defp require_field!(payload, key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key)) ||
      raise ArgumentError, "MigrationImporter: missing required field #{inspect(key)}"
  end
end
