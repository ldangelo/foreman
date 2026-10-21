defmodule ForemanServer.ProjectSettingsDTO do
  @moduledoc """
  The one wire shape of a project's settings read (`GET /api/projects/:id/settings`
  and the MCP `foreman_project_settings_get` tool): fixed string keys, explicit
  `null`s, never a bare config map.

      %{
        "project_id" => "...",
        "status" => "active" | "paused" | "archived",
        "settings" => %{"goal" => nil, "instructions" => nil, ...},
        "limits" => %{"max_concurrent_runs" => 3, "active_runs" => 0,
                      "daily_thread_cap" => nil, "threads_started_today" => 0,
                      "remaining_today" => nil, "cap_reached?" => false,
                      "resets_at" => "2026-03-05T00:00:00Z", "deferred_tasks" => 0}
      }

  `settings` carries exactly the keys of `ForemanServer.ProjectSettings`.
  `config.env` is not part of this payload at all.
  """

  alias ForemanServer.{ProjectionStore, ProjectSettings}

  @spec fetch(String.t()) :: {:ok, map()} | :not_found
  def fetch(project_id) when is_binary(project_id) do
    with %{} = project <- ProjectionStore.project_projection(project_id),
         %{} = limits <- ProjectionStore.project_limits(project_id) do
      settings = ProjectSettings.from_config(Map.get(project, :config))

      {:ok,
       %{
         "project_id" => project_id,
         "status" => Map.get(project, :status),
         "settings" =>
           settings
           |> Map.from_struct()
           |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
         "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
       }}
    else
      nil -> :not_found
    end
  end
end
