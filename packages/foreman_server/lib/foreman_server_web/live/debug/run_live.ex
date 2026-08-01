defmodule ForemanServerWeb.Debug.RunLive do
  @moduledoc false

  use Phoenix.LiveView

  alias ForemanServerWeb.Debug.Views

  @event_topic "debug:events"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ForemanServer.PubSub, @event_topic)
    end

    rows = Views.run_rows()
    selected_run_id = rows |> List.first() |> then(&(&1 && &1.run_id))

    {:ok,
     socket
     |> assign(:rows, rows)
     |> assign(:selected_run_id, selected_run_id)
     |> assign(:details, Views.run_details(selected_run_id))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rows = Views.run_rows()
    selected_run_id = params["run_id"] || socket.assigns.selected_run_id || (rows |> List.first() |> then(&(&1 && &1.run_id)))

    {:noreply,
     socket
     |> assign(:rows, rows)
     |> assign(:selected_run_id, selected_run_id)
     |> assign(:details, Views.run_details(selected_run_id))}
  end

  @impl true
  def handle_info({:debug_event, _event}, socket) do
    rows = Views.run_rows()
    selected_run_id = socket.assigns.selected_run_id || (rows |> List.first() |> then(&(&1 && &1.run_id)))

    {:noreply,
     socket
     |> assign(:rows, rows)
     |> assign(:details, Views.run_details(selected_run_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Views.shell title="Run diagnostics" section={:runs}>
      <section style="display: grid; gap: 1rem; grid-template-columns: minmax(0, 2fr) minmax(22rem, 1fr); align-items: start;">
        <article style="background: #111827; border: 1px solid #334155; border-radius: 1rem; overflow: hidden;">
          <div style="padding: 1rem 1.25rem; border-bottom: 1px solid #334155;">
            <h2 style="margin: 0; font-size: 1.1rem;">Active and recent runs</h2>
          </div>
          <div style="overflow-x: auto;">
            <table style="width: 100%; border-collapse: collapse;">
              <thead>
                <tr style="text-align: left; color: #94a3b8;">
                  <th style="padding: 0.9rem 1.25rem;">Run</th>
                  <th style="padding: 0.9rem 1.25rem;">Status</th>
                  <th style="padding: 0.9rem 1.25rem;">Current phase</th>
                  <th style="padding: 0.9rem 1.25rem;">Counts</th>
                  <th style="padding: 0.9rem 1.25rem;">Updated</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                    <.link patch={"/debug/runs?run_id=#{row.run_id}"} style="font-weight: 700; color: #bfdbfe; text-decoration: none;">
                      <%= row.run_id %>
                    </.link>
                    <div style="margin-top: 0.25rem; color: #94a3b8; font-size: 0.85rem;">
                      task <%= row.task_id || "—" %>
                    </div>
                  </td>
                  <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                    <Views.badge label={row.status} tone={Views.tone_for_status(row.status)} />
                  </td>
                  <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937;">
                    <code><%= row.current_phase || "—" %></code>
                  </td>
                  <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                    <div><%= row.phase_count %> phases</div>
                    <div><%= row.worker_count %> workers</div>
                  </td>
                  <td style="padding: 0.9rem 1.25rem; border-top: 1px solid #1f2937; color: #cbd5e1;">
                    <%= Views.format_timestamp(row.updated_at || row.last_event_time) %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </article>

        <article style="background: #111827; border: 1px solid #334155; border-radius: 1rem; padding: 1rem 1.25rem;">
          <%= if @details do %>
            <h2 style="margin-top: 0;">Selected run</h2>
            <dl style="display: grid; grid-template-columns: auto 1fr; gap: 0.6rem 1rem; margin: 0;">
              <dt style="color: #94a3b8;">Run</dt>
              <dd style="margin: 0;"><code><%= @selected_run_id %></code></dd>
              <dt style="color: #94a3b8;">Status</dt>
              <dd style="margin: 0;"><Views.badge label={@details.report.status} tone={Views.tone_for_status(@details.report.status)} /></dd>
              <dt style="color: #94a3b8;">Current phase</dt>
              <dd style="margin: 0;"><%= @details.report.current_phase || "—" %></dd>
              <dt style="color: #94a3b8;">Artifacts</dt>
              <dd style="margin: 0;"><%= Views.format_value(@details.report.artifact_paths) %></dd>
              <dt style="color: #94a3b8;">Reports</dt>
              <dd style="margin: 0;"><%= Views.format_value(@details.report.report_paths) %></dd>
            </dl>

            <h3 style="margin: 1.25rem 0 0.5rem;">Recent timeline</h3>
            <ul style="margin: 0; padding-left: 1.1rem; display: grid; gap: 0.5rem;">
              <li :for={entry <- @details.timeline}>
                <code><%= entry.type %></code>
                <span style="color: #cbd5e1;"> — phase <%= entry.phase_id || "—" %>, worker <%= entry.worker_id || "—" %></span>
              </li>
            </ul>
          <% else %>
            <p style="margin: 0; color: #94a3b8;">No run data available yet.</p>
          <% end %>
        </article>
      </section>
    </Views.shell>
    """
  end
end
