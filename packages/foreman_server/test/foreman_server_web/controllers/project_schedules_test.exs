defmodule ForemanServerWeb.ProjectSchedulesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, ProjectStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-schedules-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "sched-http-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}"})
    {:ok, id: id}
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  defp command(project_id, type, schedule_id, extra) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "#{type}-#{schedule_id}-#{System.unique_integer([:positive])}",
               type: type,
               aggregate_id: "schedule:#{project_id}:#{schedule_id}",
               payload: Map.merge(%{project_id: project_id, schedule_id: schedule_id}, extra)
             })
  end

  defp create(project_id, schedule_id, name, extra \\ %{}) do
    command(
      project_id,
      "schedule.create",
      schedule_id,
      Map.merge(
        %{
          name: name,
          spec: %{"every" => "1h", "anchor" => "2026-01-01T00:00:00Z"},
          prompt: String.duplicate("p", 600),
          workflow: "implement"
        },
        extra
      )
    )
  end

  test "lists active, paused and fired schedules with computed next_fire_at; deleted are hidden",
       %{id: id} do
    create(id, "s-active", "a-active")
    create(id, "s-paused", "b-paused")
    create(id, "s-deleted", "c-deleted")
    create(id, "s-cron", "d-cron", %{spec: %{"cron" => "0 9 * * 1-5"}})
    command(id, "schedule.pause", "s-paused", %{})
    command(id, "schedule.delete", "s-deleted", %{})

    ForemanServer.ProjectionStore.apply_events([
      %{
        event_type: "ScheduleFired",
        payload: %{
          schedule_id: "s-active",
          project_id: id,
          slot: 1_700_000_000,
          task_id: "sched-s-active-1700000000",
          intent_id: "i",
          collapsed_count: 0,
          fired_at: "2026-01-01T00:00:00Z"
        }
      }
    ])

    assert %{"ticker" => "disabled", "schedules" => schedules} =
             get_json("/api/projects/#{id}/schedules", 200)

    assert ["s-active", "s-cron", "s-paused"] ==
             schedules |> Enum.map(& &1["schedule_id"]) |> Enum.sort()

    by_id = Map.new(schedules, &{&1["schedule_id"], &1})

    # Active hourly: the next slot is the next whole hour, in the future, slot aligned.
    assert {:ok, next, 0} = DateTime.from_iso8601(by_id["s-active"]["next_fire_at"])
    assert DateTime.compare(next, DateTime.utc_now()) == :gt
    assert next.minute == 0 and next.second == 0
    assert DateTime.diff(next, DateTime.utc_now()) <= 3_600

    assert {:ok, cron_next, 0} = DateTime.from_iso8601(by_id["s-cron"]["next_fire_at"])
    assert cron_next.hour == 9 and cron_next.minute == 0
    assert Date.day_of_week(DateTime.to_date(cron_next)) in 1..5

    assert %{"status" => "paused", "next_fire_at" => nil} = by_id["s-paused"]

    assert %{
             "last_outcome" => %{"kind" => "fired", "slot" => 1_700_000_000},
             "last_task_id" => "sched-s-active-1700000000",
             "workflow" => "implement",
             "overlap" => "skip",
             "auto_approve" => true,
             "timezone" => "UTC",
             "project_id" => ^id,
             "name" => "a-active",
             "spec" => %{"every" => "1h"}
           } = by_id["s-active"]

    # List view truncates the prompt.
    assert String.length(by_id["s-active"]["prompt"]) == 500
  end

  test "sorted by next_fire_at then name, paused last", %{id: id} do
    create(id, "s1", "zeta", %{spec: %{"every" => "1h", "anchor" => "2026-01-01T00:00:00Z"}})
    create(id, "s2", "alpha", %{spec: %{"every" => "1h", "anchor" => "2026-01-01T00:00:00Z"}})
    create(id, "s3", "early", %{spec: %{"every" => "5m", "anchor" => "2026-01-01T00:00:00Z"}})
    create(id, "s4", "aaa-paused")
    command(id, "schedule.pause", "s4", %{})

    schedules = get_json("/api/projects/#{id}/schedules", 200)["schedules"]
    names = Enum.map(schedules, & &1["name"])

    # The "5m" and "1h" schedules next fire at the SAME instant during the last five
    # minutes of every hour (both land on the top of the hour), and the tie then breaks
    # by name. So the contract is asserted from the response itself - ordered by
    # (next_fire_at, name), schedules without a next fire last - not from a wall-clock
    # dependent literal list.
    keys = Enum.map(schedules, &{is_nil(&1["next_fire_at"]), &1["next_fire_at"], &1["name"]})
    assert keys == Enum.sort(keys)

    assert List.last(names) == "aaa-paused"
    assert Enum.find_index(names, &(&1 == "alpha")) < Enum.find_index(names, &(&1 == "zeta"))

    by_name = Map.new(schedules, &{&1["name"], &1["next_fire_at"]})
    assert by_name["early"] <= by_name["alpha"]
    assert by_name["alpha"] == by_name["zeta"]
  end

  test "empty project lists no schedules", %{id: id} do
    assert %{"schedules" => []} = get_json("/api/projects/#{id}/schedules", 200)
  end

  test "an unknown project is 404 with the same body as the project read" do
    assert get_json("/api/projects/nope/schedules", 404) == get_json("/api/projects/nope", 404)
  end

  test "an unauthenticated request is rejected", %{id: id} do
    assert build_conn() |> get("/api/projects/#{id}/schedules") |> json_response(401)
  end
end
