defmodule ForemanServerWeb.CommandControllerScheduleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias ForemanServer.Aggregates.Schedule, as: ScheduleAggregate
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    project_id = "sp-#{EventStore.UUID.uuid4()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
        }
      ])

    {:ok, project_id: project_id}
  end

  defp post_command(type, payload, extra \\ %{}) do
    build_conn() |> post("/api/commands", Map.merge(%{type: type, payload: payload}, extra))
  end

  defp create_payload(project_id, extra \\ %{}) do
    Map.merge(
      %{
        project_id: project_id,
        name: "weekly",
        spec: %{"every" => "1h"},
        prompt: "bump deps",
        workflow: "implement"
      },
      extra
    )
  end

  test "schedule.create without an id generates one and returns it", %{project_id: p} do
    conn = post_command("schedule.create", create_payload(p))

    assert %{"status" => "accepted", "result" => %{"project_id" => ^p, "schedule_id" => id}} =
             json_response(conn, 201)

    assert id =~ ~r/\Asch-[0-9a-f]{12}\z/

    assert %{name: "weekly", status: "active", spec: %{"every" => "1h", "anchor" => anchor}} =
             ProjectionStore.schedule(p, id)

    # The anchor is server-stamped creation time, not client supplied.
    assert {:ok, _, 0} = DateTime.from_iso8601(anchor)
  end

  test "a retried schedule.create with the same command_id and schedule_id is one schedule",
       %{project_id: p} do
    # What `foreman project schedule create` sends on a retry after a timeout.
    extra = %{command_id: "cli-retry-#{EventStore.UUID.uuid4()}"}
    payload = create_payload(p, %{schedule_id: "sch-0123456789ab"})

    first = post_command("schedule.create", payload, extra) |> json_response(201)
    second = post_command("schedule.create", payload, extra) |> json_response(201)

    assert first["result"]["replayed"] == false
    assert second["result"]["replayed"] == true
    assert put_in(first, ["result", "replayed"], true) == second
    assert %{"result" => %{"schedule_id" => "sch-0123456789ab"}} = first
    assert [%{schedule_id: "sch-0123456789ab"}] = ProjectionStore.schedules(p)
  end

  test "a client-supplied `at` cannot back-date the schedule", %{project_id: p} do
    conn = post_command("schedule.create", create_payload(p, %{at: "2000-01-01T00:00:00Z"}))
    %{"result" => %{"schedule_id" => id}} = json_response(conn, 201)
    refute ProjectionStore.schedule(p, id).created_at =~ "2000-"
  end

  test "pause, resume and delete derive the composite aggregate id", %{project_id: p} do
    %{"result" => %{"schedule_id" => id}} =
      post_command("schedule.create", create_payload(p)) |> json_response(201)

    ids = %{project_id: p, schedule_id: id}
    assert %{"status" => "accepted"} = post_command("schedule.pause", ids) |> json_response(201)
    assert ProjectionStore.schedule(p, id).status == "paused"
    assert %{"status" => "accepted"} = post_command("schedule.resume", ids) |> json_response(201)
    assert ProjectionStore.schedule(p, id).status == "active"
    assert %{"status" => "accepted"} = post_command("schedule.delete", ids) |> json_response(201)
    assert ProjectionStore.schedule(p, id).status == "deleted"

    assert %{"error" => error} = post_command("schedule.pause", ids) |> json_response(422)
    assert error =~ "schedule_deleted"
  end

  test "a mismatched aggregate_id and missing ids are rejected", %{project_id: p} do
    assert %{"error" => "invalid_envelope"} =
             post_command("schedule.pause", %{project_id: p, schedule_id: "s"}, %{
               aggregate_id: "schedule:other:s"
             })
             |> json_response(400)

    assert %{"error" => "invalid_envelope"} =
             post_command("schedule.pause", %{project_id: p}) |> json_response(400)

    assert %{"error" => "invalid_envelope"} =
             post_command("schedule.create", %{name: "x"}) |> json_response(400)
  end

  test "typed validation errors reach the response verbatim", %{project_id: p} do
    assert %{"error" => error} =
             post_command("schedule.create", create_payload(p, %{spec: %{"every" => "1m"}}))
             |> json_response(422)

    assert error == "{:invalid_schedule_spec, :every, :below_minimum}"

    assert %{"error" => unknown} =
             post_command("schedule.create", create_payload("no-such-project"))
             |> json_response(422)

    assert unknown =~ "project_not_found"
  end

  test "the system-only fire commands are not operator commands", %{project_id: p} do
    for type <- ~w(schedule.mark_fired schedule.skip_fire) do
      conn = post_command(type, %{project_id: p, schedule_id: "s", slot: 1})
      assert json_response(conn, 400)["error"] == "invalid_envelope"
    end

    for type <- ~w(schedule.mark_fired schedule.skip_fire) do
      assert {:error, {:command_not_allowed, ^type}} =
               ForemanServer.CommandGateway.dispatch_operator(%{
                 command_id: "x-#{EventStore.UUID.uuid4()}",
                 type: type,
                 aggregate_id: "schedule:#{p}:s",
                 payload: %{project_id: p, schedule_id: "s", slot: 1}
               })
    end
  end

  test "every schedule operator type the gateway lists is accepted by the controller and the gateway",
       %{project_id: p} do
    types = ForemanServer.CommandGateway.schedule_operator_types()

    assert Enum.sort(types) ==
             ~w(schedule.create schedule.delete schedule.pause schedule.resume schedule.update)

    %{"result" => %{"schedule_id" => id}} =
      post_command("schedule.create", create_payload(p)) |> json_response(201)

    # `schedule.delete` last: it ends the stream. Neither 400 (controller rejected the
    # type or envelope) nor 403 (gateway refused the type) may happen for a listed type.
    for type <- List.delete(types, "schedule.delete") ++ ["schedule.delete"] do
      conn = post_command(type, create_payload(p, %{schedule_id: id}))

      refute conn.status in [400, 403], "#{type} was refused: #{conn.resp_body}"
    end

    assert %{"error" => "invalid_envelope"} =
             post_command("schedule.fire", %{project_id: p, schedule_id: id})
             |> json_response(400)
  end

  # foreman-q9zzo C9: `foreman project schedule create --timezone America/Chicago` is accepted by
  # the CLI, which sends the flag verbatim and leaves the verdict to the server; the server takes
  # UTC only (`Schedule.Spec`). The body is the JSON `projectScheduleCreate` builds (its field
  # names), and the 422 is what the CLI prints after `foreman: HTTP 422: `
  # (`cmd/foreman/project_schedule_test.go` pins the other half with the same literal).
  describe "the timezone rule, as the CLI hits it" do
    @refusal ~s({"error":"{:invalid_schedule_spec, :timezone, :unsupported_timezone}"})

    defp cli_post(type, payload) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/commands", Jason.encode!(%{"type" => type, "payload" => payload}))
    end

    defp cli_create(project_id, schedule_id, spec) do
      cli_post("schedule.create", %{
        "schedule_id" => schedule_id,
        "project_id" => project_id,
        "name" => "n",
        "spec" => spec,
        "prompt" => "x",
        "workflow" => "implement",
        "auto_approve" => true,
        "overlap" => "skip"
      })
    end

    defp stream_types(project_id, schedule_id) do
      case ForemanServer.EventStore.read_stream_forward(
             ScheduleAggregate.stream_id(project_id, schedule_id),
             0,
             10
           ) do
        {:ok, events} -> Enum.map(events, & &1.event_type)
        {:error, :stream_not_found} -> []
      end
    end

    defp listed(project_id) do
      build_conn() |> get("/api/projects/#{project_id}/schedules") |> json_response(200)
    end

    test "a timezone other than UTC is a 422 with the typed error, and nothing is persisted",
         %{project_id: p} do
      for {id, spec} <- [
            {"s-every", %{"every" => "1h", "timezone" => "America/Chicago"}},
            {"s-cron", %{"cron" => "0 9 * * 1-5", "timezone" => "America/Chicago"}}
          ] do
        conn = cli_create(p, id, spec)

        assert response(conn, 422) == @refusal
        assert stream_types(p, id) == []
      end

      assert ProjectionStore.schedules(p) == []
      assert %{"schedules" => []} = listed(p)
    end

    test "UTC, Etc/UTC and no timezone at all still create, and are stored as UTC",
         %{project_id: p} do
      for {id, spec} <- [
            {"s-utc", %{"every" => "1h", "timezone" => "UTC"}},
            {"s-etc", %{"cron" => "0 9 * * 1-5", "timezone" => "Etc/UTC"}},
            {"s-none", %{"cron" => "0 9 * * 1-5"}}
          ] do
        assert %{"status" => "accepted", "result" => %{"schedule_id" => ^id}} =
                 json_response(cli_create(p, id, spec), 201)

        assert stream_types(p, id) == ["ScheduleCreated"]
      end

      assert %{"schedules" => schedules} = listed(p)
      assert Enum.sort(Enum.map(schedules, & &1["schedule_id"])) == ["s-etc", "s-none", "s-utc"]
      assert Enum.all?(schedules, &(&1["timezone"] == "UTC"))
    end

    test "schedule.update refuses the same timezone and keeps the stored spec", %{project_id: p} do
      assert %{"status" => "accepted"} =
               json_response(cli_create(p, "s-up", %{"every" => "1h"}), 201)

      before = ProjectionStore.schedule(p, "s-up").spec

      refused =
        cli_post("schedule.update", %{
          "project_id" => p,
          "schedule_id" => "s-up",
          "spec" => %{"every" => "2h", "timezone" => "America/Chicago"}
        })

      assert response(refused, 422) == @refusal
      assert stream_types(p, "s-up") == ["ScheduleCreated"]
      assert ProjectionStore.schedule(p, "s-up").spec == before

      accepted =
        cli_post("schedule.update", %{
          "project_id" => p,
          "schedule_id" => "s-up",
          "spec" => %{"every" => "2h", "timezone" => "UTC"}
        })

      assert %{"status" => "accepted"} = json_response(accepted, 201)
      assert stream_types(p, "s-up") == ["ScheduleCreated", "ScheduleUpdated"]
      assert %{"every" => "2h", "timezone" => "UTC"} = ProjectionStore.schedule(p, "s-up").spec
    end
  end
end
