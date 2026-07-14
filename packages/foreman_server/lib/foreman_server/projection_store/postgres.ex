defmodule ForemanServer.ProjectionStore.Postgres do
  @moduledoc "Postgres-backed read model persistence for ProjectionStore."

  alias Ecto.Adapters.SQL
  alias ForemanServer.Repo

  @projection_name "read_models"

  @spec enabled?() :: boolean()
  def enabled? do
    ForemanServer.RuntimeInfo.projection_store_adapter() == :postgres
  end

  @spec persist_changes(map(), map(), map()) :: :ok
  def persist_changes(old_projection, new_projection, event) do
    Repo.transaction(fn ->
      persist_map_changes(
        Map.get(old_projection, :projects, %{}),
        Map.get(new_projection, :projects, %{}),
        event,
        &upsert_project/2,
        &delete_project/1
      )

      persist_map_changes(
        Map.get(old_projection, :tasks, %{}),
        Map.get(new_projection, :tasks, %{}),
        event,
        &upsert_task/2,
        &delete_task/1
      )

      persist_map_changes(
        Map.get(old_projection, :runs, %{}),
        Map.get(new_projection, :runs, %{}),
        event,
        &upsert_run/2,
        &delete_run/1
      )

      persist_map_changes(
        Map.get(old_projection, :inbox_messages, %{}),
        Map.get(new_projection, :inbox_messages, %{}),
        event,
        &upsert_inbox_message/2,
        &delete_inbox_message/1
      )

      upsert_checkpoint(new_projection, event)
    end)

    :ok
  end

  @spec replace_all(map()) :: :ok
  def replace_all(projection) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "DELETE FROM foreman_inbox_message_projections", [])
      SQL.query!(Repo, "DELETE FROM foreman_run_projections", [])
      SQL.query!(Repo, "DELETE FROM foreman_task_projections", [])
      SQL.query!(Repo, "DELETE FROM foreman_project_projections", [])

      projection
      |> Map.get(:projects, %{})
      |> Map.values()
      |> Enum.each(&upsert_project(&1, nil))

      projection
      |> Map.get(:tasks, %{})
      |> Map.values()
      |> Enum.each(&upsert_task(&1, nil))

      projection
      |> Map.get(:runs, %{})
      |> Map.values()
      |> Enum.each(&upsert_run(&1, nil))

      projection
      |> Map.get(:inbox_messages, %{})
      |> Map.values()
      |> Enum.each(&upsert_inbox_message(&1, nil))

      upsert_checkpoint(projection, nil)
    end)

    :ok
  end

  @spec project(String.t()) :: map() | nil
  def project(project_id) when is_binary(project_id) do
    read_one("SELECT data FROM foreman_project_projections WHERE project_id = $1", [project_id])
  end

  @spec project_list() :: [map()]
  def project_list do
    read_many("SELECT data FROM foreman_project_projections ORDER BY project_id ASC", [])
  end

  @spec task(String.t()) :: map() | nil
  def task(task_id) when is_binary(task_id) do
    read_one("SELECT data FROM foreman_task_projections WHERE task_id = $1", [task_id])
  end

  @spec task_list() :: [map()]
  def task_list do
    read_many("SELECT data FROM foreman_task_projections ORDER BY task_id ASC", [])
  end

  defp persist_map_changes(old_map, new_map, event, upsert_fun, delete_fun) do
    old_keys = Map.keys(old_map) |> MapSet.new()
    new_keys = Map.keys(new_map) |> MapSet.new()

    old_keys
    |> MapSet.union(new_keys)
    |> Enum.each(fn key ->
      old_value = Map.get(old_map, key)
      new_value = Map.get(new_map, key)

      if old_value != new_value do
        if is_nil(new_value), do: delete_fun.(key), else: upsert_fun.(new_value, event)
      end
    end)
  end

  defp upsert_project(project, event) do
    query = """
    INSERT INTO foreman_project_projections (project_id, status, data, updated_at, last_event_id)
    VALUES ($1, $2, $3::jsonb, now(), $4)
    ON CONFLICT (project_id) DO UPDATE SET
      status = EXCLUDED.status,
      data = EXCLUDED.data,
      updated_at = now(),
      last_event_id = EXCLUDED.last_event_id
    """

    SQL.query!(Repo, query, [
      fetch_key(project, :project_id),
      get_key(project, :status),
      stringify_keys(project),
      event_id(event)
    ])
  end

  defp delete_project(project_id) do
    SQL.query!(Repo, "DELETE FROM foreman_project_projections WHERE project_id = $1", [project_id])
  end

  defp upsert_task(task, event) do
    query = """
    INSERT INTO foreman_task_projections (task_id, project_id, status, data, updated_at, last_event_id)
    VALUES ($1, $2, $3, $4::jsonb, now(), $5)
    ON CONFLICT (task_id) DO UPDATE SET
      project_id = EXCLUDED.project_id,
      status = EXCLUDED.status,
      data = EXCLUDED.data,
      updated_at = now(),
      last_event_id = EXCLUDED.last_event_id
    """

    SQL.query!(Repo, query, [
      fetch_key(task, :task_id),
      get_key(task, :project_id),
      get_key(task, :status),
      stringify_keys(task),
      event_id(event)
    ])
  end

  defp delete_task(task_id) do
    SQL.query!(Repo, "DELETE FROM foreman_task_projections WHERE task_id = $1", [task_id])
  end

  defp upsert_run(run, event) do
    query = """
    INSERT INTO foreman_run_projections (run_id, task_id, status, data, updated_at, last_event_id)
    VALUES ($1, $2, $3, $4::jsonb, now(), $5)
    ON CONFLICT (run_id) DO UPDATE SET
      task_id = EXCLUDED.task_id,
      status = EXCLUDED.status,
      data = EXCLUDED.data,
      updated_at = now(),
      last_event_id = EXCLUDED.last_event_id
    """

    SQL.query!(Repo, query, [
      fetch_key(run, :run_id),
      get_key(run, :task_id),
      get_key(run, :status),
      stringify_keys(run),
      event_id(event)
    ])
  end

  defp delete_run(run_id) do
    SQL.query!(Repo, "DELETE FROM foreman_run_projections WHERE run_id = $1", [run_id])
  end

  defp upsert_inbox_message(message, event) do
    query = """
    INSERT INTO foreman_inbox_message_projections (
      message_id, run_id, task_id, project_id, data, updated_at, last_event_id
    ) VALUES ($1, $2, $3, $4, $5::jsonb, now(), $6)
    ON CONFLICT (message_id) DO UPDATE SET
      run_id = EXCLUDED.run_id,
      task_id = EXCLUDED.task_id,
      project_id = EXCLUDED.project_id,
      data = EXCLUDED.data,
      updated_at = now(),
      last_event_id = EXCLUDED.last_event_id
    """

    SQL.query!(Repo, query, [
      fetch_key(message, :message_id),
      get_key(message, :run_id),
      get_key(message, :task_id),
      get_key(message, :project_id),
      stringify_keys(message),
      event_id(event)
    ])
  end

  defp delete_inbox_message(message_id) do
    SQL.query!(Repo, "DELETE FROM foreman_inbox_message_projections WHERE message_id = $1", [
      message_id
    ])
  end

  defp upsert_checkpoint(projection, event) do
    checkpoint = Map.get(projection, :checkpoint, %{})

    query = """
    INSERT INTO foreman_projection_checkpoints (
      projection_name, last_event_id, last_stream_version, updated_at, rebuild_started_at
    ) VALUES ($1, $2, $3, now(), now())
    ON CONFLICT (projection_name) DO UPDATE SET
      last_event_id = EXCLUDED.last_event_id,
      last_stream_version = EXCLUDED.last_stream_version,
      updated_at = now()
    """

    SQL.query!(Repo, query, [
      @projection_name,
      event_id(event) || get_key(checkpoint, :last_event_id),
      get_key(checkpoint, :last_stream_version) || 0
    ])
  end

  defp read_one(query, params) do
    case read_many(query, params) do
      [row | _] -> row
      [] -> nil
    end
  end

  defp read_many(query, params) do
    case SQL.query(Repo, query, params) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [data] -> atomize_keys(data || %{}) end)
      {:error, reason} -> raise "failed to read Foreman projection tables: #{inspect(reason)}"
    end
  end

  defp event_id(nil), do: nil
  defp event_id(%ForemanServer.Event{event_id: event_id}), do: event_id

  defp event_id(event) when is_map(event),
    do: Map.get(event, :event_id) || Map.get(event, "event_id")

  defp fetch_key(map, key) do
    get_key(map, key) || raise ArgumentError, "missing projection key #{inspect(key)}"
  end

  defp get_key(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp stringify_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_keys(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_keys(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_keys(%Time{} = value), do: Time.to_iso8601(value)

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
    |> Map.new()
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp atomize_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {safe_atom(key), atomize_keys(nested)} end)
    |> Map.new()
  end

  defp atomize_keys(value) when is_list(value), do: Enum.map(value, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp safe_atom(key) when is_atom(key), do: key

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
