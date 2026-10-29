defmodule ForemanServer.Overview.Tabs.Scheduled do
  @moduledoc """
  Scheduled tab: one row per non-deleted schedule of the project, read from the
  schedule read model through `ForemanServer.Schedule.DTO` - the same data the
  workspace's Scheduled tab lists and `GET /api/projects/:id/schedules` returns.

  A row is the `Schedule.DTO` struct as a string-keyed map (`schedule_id`, `name`,
  `status`, `next_fire_at`, `last_outcome`, ...). A project with no schedules (or an
  unknown project) has an empty list; a read-model failure raises and
  `Overview.Tabs` reports the tab as `provider_failed` rather than as an empty list.
  """

  @behaviour ForemanServer.Overview.TabProvider

  alias ForemanServer.Schedule.DTO

  @impl true
  def tab, do: :scheduled

  @impl true
  def rows(project_id) do
    project_id |> DTO.list() |> Enum.map(&row/1)
  end

  defp row(%DTO{} = dto) do
    dto |> Map.from_struct() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
