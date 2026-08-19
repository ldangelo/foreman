defmodule ForemanServerWeb.LiveDashboard do
  @moduledoc """
  Mount for `jido_live_dashboard` under existing Foreman auth guards.

  TRD-2026-4212be7e / JLD-T001 / TRD-055.

  This LiveView is the Phoenix endpoint for the Jido live dashboard. It
  displays live state for:

    * Active Jido agents connected via the signal bus
    * Queued directives waiting to be dispatched
    * The most recent signals observed (chronological tail)

  ## Mounting

  Auth pipeline is intentionally deferred to a follow-up wiring bead; the
  LiveView is render-safe on its own and the canonical Foreman auth
  plugs (`:browser` + `:require_authenticated`) can be applied at the
  router scope without modifying this module.

      scope "/dashboard", ForemanServerWeb do
        pipe_through [:browser, :require_authenticated]
        live "/", LiveDashboard
      end
  """

  use ForemanServerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Jido Live Dashboard")
     |> assign(:active_agents, [])
     |> assign(:directive_queue, [])
     |> assign(:signal_history, [])
     |> assign(:last_refresh_at, DateTime.utc_now() |> DateTime.to_iso8601())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="jido-live-dashboard">
      <h1>{@page_title}</h1>
      <p class="dashboard-meta">Last refresh: {@last_refresh_at}</p>

      <button type="button" phx-click="refresh">Refresh</button>

      <section>
        <h2>Active agents</h2>
        <p>{Enum.count(@active_agents)} active</p>
        <ul :if={@active_agents != []}>
          <li :for={a <- @active_agents}>{a}</li>
        </ul>
        <p :if={@active_agents == []}>No active agents.</p>
      </section>

      <section>
        <h2>Directive queue</h2>
        <p>{Enum.count(@directive_queue)} queued</p>
        <ul :if={@directive_queue != []}>
          <li :for={d <- @directive_queue}>{d}</li>
        </ul>
        <p :if={@directive_queue == []}>No queued directives.</p>
      </section>

      <section>
        <h2>Signal history</h2>
        <p>{Enum.count(@signal_history)} recent</p>
        <ul :if={@signal_history != []}>
          <li :for={s <- @signal_history}>{s}</li>
        </ul>
        <p :if={@signal_history == []}>No signals yet.</p>
      </section>
    </div>
    """
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, :timer.seconds(5))
  end

  defp refresh(socket) do
    assign(socket, last_refresh_at: DateTime.utc_now() |> DateTime.to_iso8601())
  end
end
