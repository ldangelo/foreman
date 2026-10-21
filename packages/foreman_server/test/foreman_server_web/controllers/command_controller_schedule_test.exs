defmodule ForemanServerWeb.CommandControllerScheduleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

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

  test "gateway and controller allowlists agree on the schedule operator types" do
    expected = ~w(schedule.create schedule.update schedule.pause schedule.resume schedule.delete)
    gateway = source_types("lib/foreman_server/command_gateway.ex", "@allowed_operator_types")

    controller =
      source_types("lib/foreman_server_web/controllers/command_controller.ex", "@allowed_types")

    assert Enum.filter(gateway, &String.starts_with?(&1, "schedule.")) |> Enum.sort() ==
             Enum.sort(expected)

    assert Enum.filter(controller, &String.starts_with?(&1, "schedule.")) |> Enum.sort() ==
             Enum.sort(expected)
  end

  defp source_types(path, attr) do
    [_, list] = Regex.run(~r/#{Regex.escape(attr)} ~w\(([^)]*)\)/, File.read!(path))
    String.split(list)
  end
end
