defmodule ForemanServer.Threads.IdleResolver do
  @moduledoc """
  Supervised reactor that resolves idle threads.

  On every sweep (once at init and every `:sweep_interval_ms`) it lists each
  project's unresolved threads and dispatches `thread.resolve` (reason `"idle"`,
  `source` `"idle"`) for those that are

    * terminal - status `completed`, `failed` or `cancelled`,
    * idle - no activity for `idle_resolve_after_days`, counted from the later
      of the thread's `updated_at` and the last `ThreadReopened` (so a reopened
      thread gets another full idle period), and
    * not tied to a pull request - a thread with a `pr_url` is left alone (the
      PR lifecycle owns it; a merge is resolved by the merge subscriber).

  Resolution is a disposition flag only; a live run is never touched. The
  `command_id` is `thread-idle:<thread_id>:<reopened_at_ms>` so re-sweeps are
  no-ops while a later reopen can still be idle-resolved again.

  Config (`config :foreman_server, :threads`): `idle_resolver` (start it, default
  `true`), `sweep_interval_ms` (default one hour), `idle_resolve_after_days`
  (default 7). Start options override config; `sweep_interval_ms: :manual`
  disables the timer so a test drives sweeps with `send(pid, :sweep)`, and
  `:now_fun` (`() -> integer` ms) injects the clock.
  """

  use GenServer
  require Logger

  alias ForemanServer.{CommandGateway, ProjectionStore, Threads}
  alias ForemanServer.Threads.Thread

  @terminal_statuses ~w(completed failed cancelled)
  @default_interval_ms :timer.hours(1)
  @default_after_days 7
  @day_ms 86_400_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Statuses the resolver treats as terminal."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @impl true
  def init(opts) do
    config = Application.get_env(:foreman_server, :threads, [])

    state = %{
      now_fun: Keyword.get(opts, :now_fun, fn -> System.os_time(:millisecond) end),
      interval:
        Keyword.get(opts, :sweep_interval_ms, config[:sweep_interval_ms] || @default_interval_ms),
      after_days:
        Keyword.get(
          opts,
          :idle_resolve_after_days,
          config[:idle_resolve_after_days] || @default_after_days
        )
    }

    if state.interval == :manual, do: {:ok, state}, else: {:ok, state, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:sweep, %{interval: :manual} = state) do
    sweep(state)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{interval: interval} = state) when is_integer(interval) do
    Process.send_after(self(), :sweep, interval)
    state
  end

  defp sweep(state) do
    cutoff = state.now_fun.() - state.after_days * @day_ms

    for %{project_id: project_id} <- ProjectionStore.list_projects(),
        is_binary(project_id),
        %Thread{} = thread <-
          Threads.list(project_id, resolved: false, limit: Threads.max_limit()),
        eligible?(thread, cutoff) do
      resolve(thread)
    end

    :ok
  rescue
    error -> Logger.warning("Threads.IdleResolver sweep failed: #{Exception.message(error)}")
  end

  defp eligible?(%Thread{status: status, pr_url: nil, updated_at: updated_at} = thread, cutoff)
       when status in @terminal_statuses and is_integer(updated_at) do
    max(updated_at, reopened_at_ms(thread.id)) < cutoff
  end

  defp eligible?(_thread, _cutoff), do: false

  defp reopened_at_ms(thread_id) do
    with %{reopened_at: at} when is_binary(at) <- ProjectionStore.thread_flags(thread_id),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> 0
    end
  end

  defp resolve(%Thread{id: id, project_id: project_id}) do
    command = %{
      command_id: "thread-idle:" <> id <> ":" <> Integer.to_string(reopened_at_ms(id)),
      type: "thread.resolve",
      aggregate_id: "thread:" <> id,
      payload: %{thread_id: id, project_id: project_id, reason: "idle", source: "idle"}
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} -> :ok
      error -> Logger.warning("Threads.IdleResolver could not resolve #{id}: #{inspect(error)}")
    end
  end
end
