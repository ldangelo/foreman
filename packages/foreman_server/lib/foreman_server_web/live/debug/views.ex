defmodule ForemanServerWeb.Debug.Views do
  @moduledoc false

  use Phoenix.Component

  alias ForemanServer.{DebugViews, ProjectionStore}
  alias ForemanServerWeb.Presence

  @presence_topic "debug:workers"
  @active_worker_statuses MapSet.new(["running", "heartbeat", "active", "started", "in_progress"])

  attr :title, :string, required: true
  attr :section, :atom, required: true
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <section class="debug-shell" style="padding: 2rem; max-width: 96rem; margin: 0 auto;">
      <header style="display: flex; flex-wrap: wrap; justify-content: space-between; gap: 1rem; align-items: center; margin-bottom: 1.5rem;">
        <div>
          <p style="margin: 0; color: #93c5fd; font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.08em;">Foreman LiveView diagnostics</p>
          <h1 style="margin: 0.35rem 0 0; font-size: 2rem;"><%= @title %></h1>
        </div>
        <nav style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
          <.nav_link href="/debug/runs" current={@section == :runs}>Runs</.nav_link>
          <.nav_link href="/debug/phases" current={@section == :phases}>Phases</.nav_link>
          <.nav_link href="/debug/workers" current={@section == :workers}>Workers</.nav_link>
        </nav>
      </header>

      <div style="display: grid; gap: 1rem;">
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  attr :href, :string, required: true
  attr :current, :boolean, default: false
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      style={[
        "padding: 0.6rem 0.9rem; border-radius: 999px; text-decoration: none; border: 1px solid #334155;",
        if(@current, do: "background: #1d4ed8; color: white;", else: "background: #111827; color: #cbd5e1;")
      ]}
    >
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  attr :label, :string, required: true
  attr :tone, :string, default: "slate"

  def badge(assigns) do
    colors = %{
      "blue" => {"#1d4ed8", "#dbeafe"},
      "green" => {"#166534", "#dcfce7"},
      "yellow" => {"#854d0e", "#fef9c3"},
      "red" => {"#991b1b", "#fee2e2"},
      "slate" => {"#334155", "#e2e8f0"},
      "violet" => {"#6d28d9", "#ede9fe"}
    }

    {bg, fg} = Map.get(colors, assigns.tone, colors["slate"])
    assigns = assign(assigns, :badge_style, "display: inline-flex; align-items: center; gap: 0.35rem; padding: 0.2rem 0.55rem; border-radius: 999px; font-size: 0.8rem; font-weight: 600; background: #{bg}; color: #{fg};")

    ~H"""
    <span style={@badge_style}><%= @label %></span>
    """
  end

  def run_rows do
    ProjectionStore.snapshot()
    |> Map.get(:runs, %{})
    |> Map.values()
    |> Enum.map(fn run ->
      %{
        run_id: Map.get(run, :run_id),
        task_id: Map.get(run, :task_id),
        status: Map.get(run, :status, "unknown"),
        current_phase: Map.get(run, :current_phase),
        updated_at: Map.get(run, :updated_at),
        last_event_time: Map.get(run, :last_event_time),
        phase_count: map_size(Map.get(run, :phase_status, %{})),
        worker_count: map_size(Map.get(run, :worker_status, %{}))
      }
    end)
    |> Enum.sort_by(&{sort_timestamp(&1.updated_at), &1.run_id}, :desc)
  end

  def run_details(nil), do: nil

  def run_details(run_id) when is_binary(run_id) do
    with {:ok, report} <- DebugViews.report(run_id),
         {:ok, timeline} <- DebugViews.debug_timeline(run_id) do
      %{report: report, timeline: Enum.take(timeline.timeline, -12)}
    else
      _ -> nil
    end
  end

  def phase_rows do
    snapshot = ProjectionStore.snapshot()
    presence = presence_list()

    snapshot
    |> Map.get(:runs, %{})
    |> Map.values()
    |> Enum.flat_map(&phase_rows_from_run(&1, snapshot, presence))
    |> Enum.sort_by(&{sort_timestamp(&1.updated_at), &1.run_id, &1.phase_id}, :desc)
  end

  def worker_rows do
    snapshot = ProjectionStore.snapshot()
    presence = presence_list()

    snapshot
    |> Map.get(:runs, %{})
    |> Map.values()
    |> Enum.flat_map(&worker_rows_from_run(&1, snapshot, presence))
    |> Enum.sort_by(&{sort_timestamp(&1.observed_at || &1.updated_at), &1.run_id, &1.worker_id}, :desc)
  end

  def tone_for_status(status) when status in ["completed", "merged"], do: "green"
  def tone_for_status(status) when status in ["heartbeat", "running", "in_progress", "live"], do: "blue"
  def tone_for_status(status) when status in ["retrying", "timed_out", "paused", "blocked"], do: "yellow"
  def tone_for_status(status) when status in ["failed", "crashed", "unresponsive", "exited"], do: "red"
  def tone_for_status(_status), do: "slate"

  def format_timestamp(nil), do: "—"
  def format_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_timestamp(value), do: to_string(value)

  def format_value(nil), do: "—"
  def format_value(value) when is_binary(value), do: value
  def format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)
  def format_value(value) when is_map(value), do: inspect(value, pretty: true, limit: :infinity)
  def format_value(value), do: inspect(value)

  defp phase_rows_from_run(run, snapshot, presence) do
    worker_rows = worker_rows_from_run(run, snapshot, presence)

    run
    |> phase_ids_for_run()
    |> Enum.map(fn phase_id ->
      phase_workers = Enum.filter(worker_rows, &(&1.phase_id == phase_id))

      %{
        id: "#{Map.get(run, :run_id)}:#{phase_id}",
        run_id: Map.get(run, :run_id),
        phase_id: phase_id,
        status:
          get_in(run, [:phase_status, phase_id]) ||
            if(Map.get(run, :current_phase) == phase_id, do: "in_progress", else: "pending"),
        current?: Map.get(run, :current_phase) == phase_id,
        workers: Enum.map(phase_workers, & &1.worker_id),
        worker_states: Enum.map(phase_workers, &"#{&1.worker_id} (#{&1.status})"),
        updated_at: Map.get(run, :updated_at)
      }
    end)
  end

  defp phase_ids_for_run(run) do
    ((Map.get(run, :phase_order, []) || []) ++ Map.keys(Map.get(run, :phase_status, %{})))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp worker_rows_from_run(run, snapshot, presence) do
    worker_ids =
      run
      |> Map.get(:worker_status, %{})
      |> Map.keys()
      |> Enum.uniq()

    Enum.map(worker_ids, fn worker_id ->
      key = worker_key(Map.get(run, :run_id), worker_id)
      meta = presence |> Map.get(key) |> presence_meta()
      heartbeat = get_in(snapshot, [:worker_heartbeats, key]) || %{}
      attach = map_value(heartbeat, :attach) || map_value(meta, :attach) || %{}
      observed_at = map_value(heartbeat, :observed_at) || map_value(meta, :observed_at)

      %{
        id: key,
        run_id: Map.get(run, :run_id),
        phase_id: map_value(heartbeat, :phase_id) || map_value(meta, :phase_id) || Map.get(run, :current_phase),
        worker_id: worker_id,
        adapter: map_value(meta, :adapter) || Map.get(run, :adapter),
        sequence: get_in(snapshot, [:worker_sequences, key]),
        status: map_value(meta, :status) || get_in(run, [:worker_status, worker_id]) || "unknown",
        liveness: if(meta == %{}, do: "offline", else: "live"),
        observed_at: observed_at,
        attach: attach,
        updated_at: Map.get(run, :updated_at)
      }
    end)
  end

  defp presence_list do
    if Process.whereis(Presence) do
      Presence.list(@presence_topic)
    else
      %{}
    end
  end

  defp presence_meta(%{metas: [meta | _]}), do: Map.delete(meta, :phx_ref)
  defp presence_meta(_value), do: %{}

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp worker_key(run_id, worker_id), do: "#{run_id}:#{worker_id}"

  defp sort_timestamp(nil), do: 0
  defp sort_timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp sort_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp sort_timestamp(_value), do: 0

  def active_worker_status?(status) when is_binary(status), do: MapSet.member?(@active_worker_statuses, status)
  def active_worker_status?(_status), do: false
end
