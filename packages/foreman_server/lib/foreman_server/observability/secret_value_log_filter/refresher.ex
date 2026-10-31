defmodule ForemanServer.Observability.SecretValueLogFilter.Refresher do
  @moduledoc """
  Keeps `ForemanServer.Observability.SecretValueLogFilter`'s value list current.

  Every `interval_ms` (default 30 s), on `refresh/0` (a cast; `SecretStore.put/3` and
  `delete/2` call it after a successful write) and on `refresh_sync/0` (a call, for tests), it
  collects the values to redact from EVERY registered project and publishes them. A log line
  does not say which project it belongs to, so the list is global.

  Per project the list is `ProjectEnvironment.fetch_secrets/1` (the persisted-text list). A
  project whose environment that refuses (for example `reserved_project_env_keys`) falls back to
  its secret-store values alone, so the highest-risk class stays covered; a project whose store
  cannot be read contributes nothing. Neither ever stops the other projects.

  When the project list itself cannot be read (the projection is down) the PREVIOUS list stays
  published: an outage must not switch the protection off. Each failure is logged once when it
  starts, with the project id and the error code only, never a name or a value, and again only
  after it has cleared and recurred.
  """
  use GenServer

  require Logger

  alias ForemanServer.Observability.SecretValueLogFilter
  alias ForemanServer.{ProjectEnvironment, ProjectStore, SecretStore}

  @default_interval_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for a refresh and returns at once. A no-op when the refresher is not running."
  @spec refresh() :: :ok
  def refresh do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :refresh)
    end
  end

  @doc "Refreshes and returns when the new list is published."
  @spec refresh_sync() :: :ok
  def refresh_sync, do: GenServer.call(__MODULE__, :refresh, 30_000)

  @doc """
  The values one project contributes: `{:ok, values}`, `{:partial, values}` (its environment was
  refused, only the store's values), or `{:error, code}` (the store was unreadable).
  """
  @spec project_values(String.t()) ::
          {:ok, [String.t()]} | {:partial, [String.t()]} | {:error, atom()}
  def project_values(project_id) when is_binary(project_id) do
    case ProjectEnvironment.fetch_secrets(project_id) do
      {:ok, values} -> {:ok, values}
      {:error, _reason} -> stored_values(project_id)
    end
  rescue
    _ -> {:error, :raised}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp stored_values(project_id) do
    case SecretStore.pairs(project_id) do
      {:ok, pairs} -> {:partial, Map.values(pairs)}
      {:error, %SecretStore.Error{code: code}} -> {:error, code}
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, %{interval: interval, failing: MapSet.new()}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    state = load(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = load(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, load(state)}

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_state), do: :ok

  defp load(state) do
    case project_ids() do
      {:ok, ids} ->
        results = Enum.map(ids, &{&1, project_values(&1)})
        values = Enum.flat_map(results, &contributed/1)
        SecretValueLogFilter.publish(values)
        report(state, results)

      {:error, reason} ->
        report_list_failure(state, reason)
    end
  end

  defp contributed({_id, {tag, values}}) when tag in [:ok, :partial], do: values
  defp contributed({_id, {:error, _code}}), do: []

  # `ProjectStore.list/0` is a call into the projection: it exits when the projection is down.
  defp project_ids do
    {:ok, Enum.map(ProjectStore.list(), & &1.project_id)}
  rescue
    error -> {:error, {:project_list, error.__struct__}}
  catch
    :exit, _ -> {:error, {:project_list, :projection_unavailable}}
  end

  defp report(state, results) do
    failing =
      for {id, outcome} <- results, reason = failure_of(outcome), into: MapSet.new() do
        {id, reason}
      end

    for {id, reason} <- failing, not MapSet.member?(state.failing, {id, reason}) do
      Logger.warning(
        "SecretValueLogFilter: project #{inspect(id)} contributes #{describe(reason)} to the " <>
          "log redaction list"
      )
    end

    %{state | failing: failing}
  end

  defp failure_of({:ok, _values}), do: nil
  defp failure_of({:partial, _values}), do: :environment_refused
  defp failure_of({:error, code}), do: code

  defp describe(:environment_refused), do: "its stored secrets only (environment refused)"
  defp describe(code), do: "no values (#{inspect(code)})"

  defp report_list_failure(state, reason) do
    key = {:list, reason}

    unless MapSet.member?(state.failing, key) do
      Logger.warning(
        "SecretValueLogFilter: cannot list projects (#{inspect(reason)}); keeping the " <>
          "previous redaction list"
      )
    end

    %{state | failing: MapSet.new([key])}
  end
end
