defmodule ForemanServerWeb.OverviewScheduledTabTest do
  # foreman-q9zzo C6: the Scheduled tab is NOT served through the Overview. `Overview.Tabs`
  # has no provider for `scheduled` (docs/user-guide.md, "Project Overview": the tab reads
  # `{"available": false, "rows": []}` until a provider registers), so `GET
  # /api/projects/:id/overview` and the MCP `foreman_overview` tool report it unavailable
  # whatever schedules exist. The schedules themselves are read from the schedule read
  # model (`Schedule.DTO`: "the data behind the Scheduled tab"), which is what the
  # workspace's Scheduled tab lists. One real schedule, three surfaces.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.{Context, Frame, Response}
  alias ForemanServer.MCP
  alias ForemanServer.ProjectStore
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset}

  @endpoint ForemanServerWeb.Endpoint
  @token "overview-scheduled-tab-token"
  @unavailable %{"available" => false, "rows" => []}

  setup do
    Eventually.put_env_for_test(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    id = "sched-tab-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Schedules"})

    # The schedule is created the way an operator does it: `schedule.create` over HTTP.
    created =
      api_conn()
      |> post("/api/commands", %{
        type: "schedule.create",
        payload: %{
          project_id: id,
          name: "nightly triage",
          spec: %{"every" => "1h"},
          prompt: "triage the new issues",
          workflow: "implement"
        }
      })
      |> json_response(201)

    assert %{"status" => "accepted", "result" => %{"schedule_id" => schedule_id}} = created

    # It exists, and is listed where the Scheduled tab's data lives.
    assert %{"schedules" => [%{"schedule_id" => ^schedule_id, "name" => "nightly triage"}]} =
             api_conn() |> get("/api/projects/#{id}/schedules") |> json_response(200)

    {:ok, id: id, schedule_id: schedule_id}
  end

  defp api_conn, do: build_conn() |> put_req_header("authorization", "Bearer #{@token}")

  # A tool call as the MCP transport delivers it: the JSON arguments are validated into
  # the tool's atom keys, the bearer token comes from the frame's headers, and the
  # reply is the JSON text an agent reads.
  defp mcp_call(name, arguments) do
    tool = Enum.find(MCP.__components__(:tool), &(&1.name == name))
    assert {:ok, args} = tool.validate_input.(arguments)
    frame = %{Frame.new() | context: %Context{headers: %{"authorization" => "Bearer #{@token}"}}}

    assert {:reply, %Response{content: [%{"type" => "text", "text" => json}]}, _frame} =
             MCP.handle_tool_call(name, args, frame)

    Jason.decode!(json)
  end

  test "GET /api/projects/:id/overview reports tabs.scheduled unavailable although a schedule exists",
       %{id: id} do
    body = api_conn() |> get("/api/projects/#{id}/overview") |> json_response(200)

    assert body["tabs"]["scheduled"] == @unavailable
    # The other tabs are served by their providers: only `scheduled` lacks one.
    assert body["tabs"] |> Map.keys() |> Enum.sort() == ~w(library pull_requests scheduled)
    assert %{"available" => true} = body["tabs"]["library"]
    assert %{"available" => true} = body["tabs"]["pull_requests"]
  end

  test "the MCP foreman_overview tool reports the same tabs.scheduled", %{
    id: id,
    schedule_id: schedule_id
  } do
    overview = mcp_call("foreman_overview", %{"project_id" => id})

    assert overview["tabs"]["scheduled"] == @unavailable
    assert overview["tabs"] |> Map.keys() |> Enum.sort() == ~w(library pull_requests scheduled)

    # Agents find the schedule through the schedule tool instead.
    assert %{"schedules" => [%{"schedule_id" => ^schedule_id, "status" => "active"}]} =
             mcp_call("foreman_schedule_list", %{"project_id" => id})
  end

  test "the workspace's Scheduled tab lists the schedule from the schedule read model", %{
    id: id,
    schedule_id: schedule_id
  } do
    {:ok, view, _html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")

    view |> element("#tab-scheduled") |> render_click()

    assert has_element?(view, "#panel-scheduled td", "nightly triage")
    assert has_element?(view, "#panel-scheduled td", "active")

    assert has_element?(
             view,
             ~s(#panel-scheduled button[phx-click="schedule"][phx-value-id="#{schedule_id}"]),
             "Pause nightly triage"
           )

    refute has_element?(view, "#panel-scheduled", "No schedules.")
    refute has_element?(view, "#panel-scheduled", "Not available yet.")
  end
end
