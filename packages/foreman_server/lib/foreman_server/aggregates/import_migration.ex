defmodule ForemanServer.Aggregates.ImportMigration do
  @moduledoc "Import migration aggregate: validates import batch lifecycle and record idempotency."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :completed?]
    defstruct [:exists?, :completed?, :import_id, records: MapSet.new()]
  end

  @impl true
  def initial_state,
    do: %State{exists?: false, completed?: false, import_id: nil, records: MapSet.new()}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "MigrationImportStarted" ->
        import_id =
          Aggregate.get(payload, :import_id) ||
            Aggregate.get(payload, :migration_id)

        %State{state | exists?: true, completed?: false, import_id: import_id}

      "MigrationRecordImported" ->
        record_id = record_id(payload)

        %State{state | records: MapSet.put(state.records || MapSet.new(), record_id)}

      "MigrationImportCompleted" ->
        import_id =
          Aggregate.get(payload, :import_id) ||
            Aggregate.get(payload, :migration_id)

        %State{state | exists?: true, completed?: true, import_id: import_id}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "migration.import.start", payload: payload}) do
    with {:ok, import_id} <- import_id(payload),
         :ok <- require_absent(state) do
      {:ok,
       %{
         stream_id: "migration:#{escape(import_id)}",
         event_type: "MigrationImportStarted",
         payload: put_import_id(payload, import_id)
       }}
    end
  end

  def handle_command(state, %{type: "migration.record.import", payload: payload}) do
    with {:ok, import_id} <- import_id(payload),
         :ok <- require_active(state),
         :ok <- reject_duplicate_record(state, record_id(payload)) do
      {:ok,
       %{
         stream_id: "migration:#{escape(import_id)}",
         event_type: "MigrationRecordImported",
         payload: put_import_id(payload, import_id)
       }}
    end
  end

  def handle_command(state, %{type: "migration.import.complete", payload: payload}) do
    with {:ok, import_id} <- import_id(payload),
         :ok <- require_active(state) do
      {:ok,
       %{
         stream_id: "migration:#{escape(import_id)}",
         event_type: "MigrationImportCompleted",
         payload: put_import_id(payload, import_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp import_id(payload) do
    payload
    |> first_present([:import_id, :migration_id])
    |> Aggregate.required_binary(:import_id)
  end

  defp put_import_id(payload, import_id) do
    payload
    |> Map.put(:import_id, import_id)
    |> Map.put_new(:migration_id, import_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp record_id(payload) do
    first_present(payload, [:record_id, :id]) ||
      "#{Aggregate.get(payload, :record_type, "record")}:#{Aggregate.get(payload, :import_index, "unknown")}"
  end

  defp require_absent(%State{exists?: true}), do: {:error, :migration_import_already_started}
  defp require_absent(_state), do: :ok

  defp require_active(%State{exists?: false}), do: {:error, :migration_import_not_started}
  defp require_active(%State{completed?: true}), do: {:error, :migration_import_completed}
  defp require_active(_state), do: :ok

  defp reject_duplicate_record(_state, nil), do: :ok

  defp reject_duplicate_record(%State{records: records}, record_id) do
    if MapSet.member?(records || MapSet.new(), record_id),
      do: {:error, {:migration_record_already_imported, record_id}},
      else: :ok
  end

  defp escape(value), do: String.replace(value, ":", "%3A")
end
