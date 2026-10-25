defmodule ForemanServer.Overview.MergeResolver do
  @moduledoc """
  Resolves a thread once its pull request is merged.

  Subscribes to `ProjectionStore` (`replay_existing: false`: a restart must not
  re-resolve history) and reacts to `PrMerged` and `PrUpdated` events. The event
  only names the run; the decision is taken from the folded PR state
  (`ProjectionStore.pr_state/1`), so a `PrUpdated` that is not a merge, or a
  malformed payload the fold skipped, never resolves anything.

  The command is `thread.resolve` (reason `"pr_merged"`, `source`/`resolved_by`
  `"system"`) dispatched through `CommandGateway.dispatch_system/1` with
  `command_id` `thread-merged:<thread_id>:<head_sha | pr_number | "merged">`, so
  a duplicate event resolves exactly once.

  A **catch-up sweep** at init resolves threads whose PR merged while the server
  was down (one pass over each project's merged PR states, at most
  `:catch_up_limit` resolutions). A thread the operator reopened after the merge
  is left alone: a merge counts only if it is newer than the thread's
  `reopened_at`; when the merge time is unknown, any reopen wins.

  Only the disposition flag is touched. Closed-without-merge PRs are classified
  `:resolved` by `Overview.Group` but are **not** auto-resolved here: the
  disposition of abandoned work stays the operator's. This module never merges
  and never approves; it dispatches nothing but `thread.resolve`.

  Options: `:name`, `:catch_up` (default `true`). Config
  (`config :foreman_server, :overview`): `merge_resolver` (start it, default
  `true`), `catch_up_limit` (default 1000).
  """

  use GenServer
  require Logger

  alias ForemanServer.{Aggregate, CommandGateway, ProjectionStore, Threads}
  alias ForemanServer.Threads.Thread

  @default_catch_up_limit 1000
  @merge_events ~w(PrMerged PrUpdated)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok ->
        state = %{catch_up: Keyword.get(opts, :catch_up, true)}
        if state.catch_up, do: {:ok, state, {:continue, :catch_up}}, else: {:ok, state}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:catch_up, state) do
    catch_up()
    {:noreply, state}
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    with type when type in @merge_events <- Aggregate.get(event, :event_type),
         run_id when is_binary(run_id) and run_id != "" <- run_id(event) do
      resolve_run(run_id)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A live event is by definition newer than any earlier reopen.
  defp resolve_run(run_id) do
    with %{project_id: project_id} when is_binary(project_id) <- ProjectionStore.run(run_id),
         %{pr_state: :merged} = pr <- ProjectionStore.pr_state(run_id),
         %Thread{} = thread <- unresolved_thread(project_id, run_id) do
      resolve(thread, pr)
    end

    :ok
  end

  defp catch_up do
    limit =
      Application.get_env(:foreman_server, :overview, [])
      |> Keyword.get(:catch_up_limit, @default_catch_up_limit)

    ProjectionStore.list_projects()
    |> Enum.flat_map(&catch_up_project/1)
    |> Enum.take(limit)
    |> Enum.each(fn {thread, pr} -> resolve(thread, pr) end)
  end

  defp catch_up_project(%{project_id: project_id}) when is_binary(project_id) do
    merged =
      for {run_id, %{pr_state: :merged} = pr} <- ProjectionStore.pr_states_for_project(project_id),
          do: {run_id, pr}

    if merged == [] do
      []
    else
      threads = Threads.list(project_id, resolved: false, limit: Threads.max_limit())

      for {run_id, pr} <- merged,
          %Thread{} = thread <- [Enum.find(threads, &(run_id in &1.run_ids))],
          merge_after_reopen?(thread, pr) do
        {thread, pr}
      end
      |> Enum.uniq_by(fn {thread, _pr} -> thread.id end)
    end
  end

  defp catch_up_project(_project), do: []

  defp unresolved_thread(project_id, run_id) do
    project_id
    |> Threads.list(resolved: false, limit: Threads.max_limit())
    |> Enum.find(&(run_id in &1.run_ids))
  end

  # A reopened thread stays open unless the merge is provably newer.
  defp merge_after_reopen?(%Thread{id: id}, pr) do
    case reopened_at_ms(id) do
      nil -> true
      reopened_ms -> is_integer(pr.pr_updated_at) and pr.pr_updated_at > reopened_ms
    end
  end

  defp reopened_at_ms(thread_id) do
    with %{reopened_at: at} when is_binary(at) <- ProjectionStore.thread_flags(thread_id),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> nil
    end
  end

  defp resolve(%Thread{id: id, project_id: project_id}, pr) do
    discriminator = pr.head_sha || (pr.pr_number && Integer.to_string(pr.pr_number)) || "merged"

    command = %{
      command_id: "thread-merged:" <> id <> ":" <> discriminator,
      type: "thread.resolve",
      aggregate_id: "thread:" <> id,
      payload: %{
        thread_id: id,
        project_id: project_id,
        reason: "pr_merged",
        resolved_by: "system",
        source: "system"
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} -> :ok
      error -> Logger.warning("Overview.MergeResolver could not resolve #{id}: #{inspect(error)}")
    end
  end

  defp run_id(event) do
    case Aggregate.get(event, :data) || Aggregate.get(event, :payload) do
      %{} = data -> Aggregate.get(data, :run_id)
      _ -> nil
    end
  end
end
