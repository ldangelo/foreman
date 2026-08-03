defmodule ForemanServer.DebugViews do
  @moduledoc false

  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.Aggregator

  @type aggregate_snapshot :: %{aggregate_id: String.t(), pid: pid(), state: struct() | map()}

  def list_runs, do: list_by_prefix("run:")
  def list_phases, do: list_by_prefix("phase:")
  def list_workers, do: list_by_prefix("worker:")

  def get_run(run_id), do: get_snapshot("run:" <> run_id)
  def get_phase(run_id, phase_id), do: get_snapshot("phase:#{run_id}:#{phase_id}")
  def get_worker(run_id, worker_id), do: get_snapshot("worker:#{run_id}:#{worker_id}")

  defp list_by_prefix(prefix) do
    Aggregator
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {aggregate_id, pid, :worker, [Actor]} when is_binary(aggregate_id) and is_pid(pid) ->
        if String.starts_with?(aggregate_id, prefix) and Process.alive?(pid) do
          [%{aggregate_id: aggregate_id, pid: pid, state: Actor.get_state(pid)}]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.sort_by(& &1.aggregate_id)
  end

  defp get_snapshot(aggregate_id) do
    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _value}] when is_pid(pid) ->
        %{aggregate_id: aggregate_id, pid: pid, state: Actor.get_state(pid)}

      _ ->
        nil
    end
  end
end

defmodule ForemanServerWeb.DebugDashboardLive do
  use ForemanServerWeb, :live_view

  alias ForemanServer.DebugViews

  @refresh_interval :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    section =
      case socket.assigns.live_action do
        :runs -> :runs
        :phases -> :phases
        :workers -> :workers
        _ -> nil
      end

    socket =
      socket
      |> assign(:section, section)
      |> assign(:page_title, page_title(section))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "runs")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "phases")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "workers")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "debug:aggregates")
      :timer.send_interval(@refresh_interval, :refresh)
    end

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="debug-dashboard">
      <h1>{@page_title}</h1>
      <button type="button" phx-click="refresh">Refresh</button>

      <section :if={@section in [nil, :runs]}>
        <h2>Runs</h2>
        <ul>
          <li :for={run <- @runs}>
            <a href={"/debug/runs/#{run.state.run_id}"}>{run.state.run_id}</a>
            <span> — {run.state.status || "unknown"}</span>
          </li>
          <li :if={@runs == []}>No run actors are currently loaded.</li>
        </ul>
      </section>

      <section :if={@section in [nil, :phases]}>
        <h2>Phases</h2>
        <ul>
          <li :for={phase <- @phases}>
            <a href={"/debug/phases/#{phase.state.run_id}/#{phase.state.phase_id}"}>{phase.state.phase_id}</a>
            <span> — {phase.state.status || "unknown"}</span>
          </li>
          <li :if={@phases == []}>No phase actors are currently loaded.</li>
        </ul>
      </section>

      <section :if={@section in [nil, :workers]}>
        <h2>Workers</h2>
        <ul>
          <li :for={worker <- @workers}>
            <a href={"/debug/workers/#{worker.state.run_id}/#{worker.state.worker_id}"}>{worker.state.worker_id}</a>
            <span> — {worker.state.status || "unknown"}</span>
          </li>
          <li :if={@workers == []}>No worker actors are currently loaded.</li>
        </ul>
      </section>
    </div>
    """
  end

  defp refresh(socket) do
    assign(socket,
      runs: DebugViews.list_runs(),
      phases: DebugViews.list_phases(),
      workers: DebugViews.list_workers()
    )
  end

  defp page_title(nil), do: "Debug dashboard"
  defp page_title(:runs), do: "Debug · Runs"
  defp page_title(:phases), do: "Debug · Phases"
  defp page_title(:workers), do: "Debug · Workers"
end

defmodule ForemanServerWeb.RunDebugLive do
  use ForemanServerWeb, :live_view

  alias ForemanServer.DebugViews

  @refresh_interval :timer.minutes(1)

  @impl true
  def mount(params, session, socket) do
    run_id = required_param!(params, session, "run_id")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "runs")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "runs:#{run_id}")
      :timer.send_interval(@refresh_interval, :refresh)
    end

    {:ok, socket |> assign(:run_id, run_id) |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="run-debug">
      <h1>Run debug: {@run_id}</h1>
      <button type="button" phx-click="refresh">Refresh</button>
      <%= if @snapshot do %>
        <p>Status: {@snapshot.state.status || "unknown"}</p>
        <p>Task: {@snapshot.state.task_id || "n/a"}</p>
        <p>PID: {inspect(@snapshot.pid)}</p>
        <pre>{inspect(@snapshot.state, pretty: true)}</pre>
      <% else %>
        <p>Run actor not loaded.</p>
      <% end %>
    </div>
    """
  end

  defp refresh(socket) do
    assign(socket, :snapshot, DebugViews.get_run(socket.assigns.run_id))
  end

  defp required_param!(params, session, key) do
    Map.get(params, key) || Map.get(session, key) || raise ArgumentError, "missing #{key}"
  end
end

defmodule ForemanServerWeb.PhaseDebugLive do
  use ForemanServerWeb, :live_view

  alias ForemanServer.DebugViews

  @refresh_interval :timer.minutes(1)

  @impl true
  def mount(params, session, socket) do
    run_id = required_param!(params, session, "run_id")
    phase_id = required_param!(params, session, "phase_id")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "phases")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "phases:#{phase_id}")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "runs:#{run_id}")
      :timer.send_interval(@refresh_interval, :refresh)
    end

    {:ok,
     socket
     |> assign(:run_id, run_id)
     |> assign(:phase_id, phase_id)
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phase-debug">
      <h1>Phase debug: {@phase_id}</h1>
      <button type="button" phx-click="refresh">Refresh</button>
      <%= if @snapshot do %>
        <p>Run: {@run_id}</p>
        <p>Status: {@snapshot.state.status || "unknown"}</p>
        <p>Attempt: {@snapshot.state.attempt}</p>
        <p>PID: {inspect(@snapshot.pid)}</p>
        <pre>{inspect(@snapshot.state, pretty: true)}</pre>
      <% else %>
        <p>Phase actor not loaded.</p>
      <% end %>
    </div>
    """
  end

  defp refresh(socket) do
    assign(socket, :snapshot, DebugViews.get_phase(socket.assigns.run_id, socket.assigns.phase_id))
  end

  defp required_param!(params, session, key) do
    Map.get(params, key) || Map.get(session, key) || raise ArgumentError, "missing #{key}"
  end
end

defmodule ForemanServerWeb.WorkerDebugLive do
  use ForemanServerWeb, :live_view

  alias ForemanServer.DebugViews

  @refresh_interval :timer.minutes(1)

  @impl true
  def mount(params, session, socket) do
    run_id = required_param!(params, session, "run_id")
    worker_id = required_param!(params, session, "worker_id")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "workers")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "workers:#{worker_id}")
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, "runs:#{run_id}")
      :timer.send_interval(@refresh_interval, :refresh)
    end

    {:ok,
     socket
     |> assign(:run_id, run_id)
     |> assign(:worker_id, worker_id)
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="worker-debug">
      <h1>Worker debug: {@worker_id}</h1>
      <button type="button" phx-click="refresh">Refresh</button>
      <%= if @snapshot do %>
        <p>Run: {@run_id}</p>
        <p>Status: {@snapshot.state.status || "unknown"}</p>
        <p>Tool events: {@snapshot.state.tool_events}</p>
        <p>Assistant messages: {@snapshot.state.assistant_messages}</p>
        <p>PID: {inspect(@snapshot.pid)}</p>
        <pre>{inspect(@snapshot.state, pretty: true)}</pre>
      <% else %>
        <p>Worker actor not loaded.</p>
      <% end %>
    </div>
    """
  end

  defp refresh(socket) do
    assign(socket, :snapshot, DebugViews.get_worker(socket.assigns.run_id, socket.assigns.worker_id))
  end

  defp required_param!(params, session, key) do
    Map.get(params, key) || Map.get(session, key) || raise ArgumentError, "missing #{key}"
  end
end
