defmodule ForemanServerWeb.Debug.WorkerLive do
  @moduledoc false

  use Phoenix.LiveView

  alias Phoenix.Socket.Broadcast
  alias ForemanServerWeb.Debug.Views

  @event_topic "debug:events"
  @presence_topic "debug:workers"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, @event_topic)
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, @presence_topic)
    end

    {:ok, assign(socket, :rows, Views.worker_rows())}
  end

  @impl true
  def handle_info({:debug_event, _event}, socket) do
    {:noreply, assign(socket, :rows, Views.worker_rows())}
  end

  def handle_info(%Broadcast{topic: @presence_topic, event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :rows, Views.worker_rows())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Views.shell title="Worker diagnostics" section={:workers}>
      <article style="background: #111827; border: 1px solid #334155; border-radius: 1rem; overflow: hidden;">
        <div style="padding: 1rem 1.25rem; border-bottom: 1px solid #334155; display: flex; justify-content: space-between; gap: 1rem; flex-wrap: wrap;">
          <div>
            <h2 style="margin: 0; font-size: 1.1rem;">Worker liveness and latest heartbeat</h2>
            <p style="margin: 0.35rem 0 0; color: #94a3b8;">Presence-backed view refreshed by event broadcasts.</p>
          </div>
        </div>

        <div style="overflow-x: auto;">
          <table style="width: 100%; border-collapse: collapse;">
            <thead>
              <tr style="text-align: left; color: #94a3b8;">
                <th style="padding: 0.9rem 1.25rem;">Worker</th>
                <th style="padding: 0.9rem 1.25rem;">Run / phase</th>
                <th style="padding: 0.9rem 1.25rem;">State</th>
                <th style="padding: 0.9rem 1.25rem;">Heartbeat</th>
                <th style="padding: 0.9rem 1.25rem;">Attach</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                  <code><%= row.worker_id %></code>
                  <div style="margin-top: 0.25rem; color: #94a3b8; font-size: 0.85rem;">adapter <%= row.adapter || "—" %></div>
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                  <div><code><%= row.run_id %></code></div>
                  <div style="margin-top: 0.25rem;">phase <code><%= row.phase_id || "—" %></code></div>
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; display: grid; gap: 0.4rem;">
                  <Views.badge label={row.status} tone={Views.tone_for_status(row.status)} />
                  <Views.badge label={row.liveness} tone={Views.tone_for_status(row.liveness)} />
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                  <div>seq <%= row.sequence || 0 %></div>
                  <div style="margin-top: 0.25rem;"><%= Views.format_timestamp(row.observed_at) %></div>
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                  <pre style="margin: 0; white-space: pre-wrap;"><%= Views.format_value(row.attach) %></pre>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </article>
    </Views.shell>
    """
  end
end
