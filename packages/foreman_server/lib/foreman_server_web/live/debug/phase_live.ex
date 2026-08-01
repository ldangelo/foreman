defmodule ForemanServerWeb.Debug.PhaseLive do
  @moduledoc false

  use Phoenix.LiveView

  alias ForemanServerWeb.Debug.Views

  @event_topic "debug:events"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, @event_topic)
    end

    {:ok, assign(socket, :rows, Views.phase_rows())}
  end

  @impl true
  def handle_info({:debug_event, _event}, socket) do
    {:noreply, assign(socket, :rows, Views.phase_rows())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Views.shell title="Phase diagnostics" section={:phases}>
      <article style="background: #111827; border: 1px solid #334155; border-radius: 1rem; overflow: hidden;">
        <div style="padding: 1rem 1.25rem; border-bottom: 1px solid #334155; display: flex; justify-content: space-between; gap: 1rem; flex-wrap: wrap;">
          <div>
            <h2 style="margin: 0; font-size: 1.1rem;">Per-phase execution state</h2>
            <p style="margin: 0.35rem 0 0; color: #94a3b8;">Derived from run projections and worker liveness.</p>
          </div>
        </div>

        <div style="overflow-x: auto;">
          <table style="width: 100%; border-collapse: collapse;">
            <thead>
              <tr style="text-align: left; color: #94a3b8;">
                <th style="padding: 0.9rem 1.25rem;">Run</th>
                <th style="padding: 0.9rem 1.25rem;">Phase</th>
                <th style="padding: 0.9rem 1.25rem;">Status</th>
                <th style="padding: 0.9rem 1.25rem;">Workers</th>
                <th style="padding: 0.9rem 1.25rem;">Updated</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;"><code><%= row.run_id %></code></td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                  <code><%= row.phase_id %></code>
                  <div :if={row.current?} style="margin-top: 0.25rem; color: #93c5fd; font-size: 0.8rem;">current</div>
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                  <Views.badge label={row.status} tone={Views.tone_for_status(row.status)} />
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                  <%= if row.worker_states == [] do %>
                    —
                  <% else %>
                    <%= Enum.join(row.worker_states, ", ") %>
                  <% end %>
                </td>
                <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                  <%= Views.format_timestamp(row.updated_at) %>
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
