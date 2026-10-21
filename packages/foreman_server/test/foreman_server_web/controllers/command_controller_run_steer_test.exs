defmodule ForemanServerWeb.CommandControllerRunSteerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @moduletag :controller

  @endpoint ForemanServerWeb.Endpoint

  defmodule CapturingGateway do
    def dispatch_operator(command) do
      send(
        Application.fetch_env!(:foreman_server, :command_controller_steer_test_pid),
        {:controller_command, command}
      )

      {:ok, %{accepted: true}}
    end
  end

  setup do
    previous = Application.get_env(:foreman_server, :command_gateway_module)
    Application.put_env(:foreman_server, :command_gateway_module, CapturingGateway)
    Application.put_env(:foreman_server, :command_controller_steer_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:foreman_server, :command_controller_steer_test_pid)

      if previous == nil,
        do: Application.delete_env(:foreman_server, :command_gateway_module),
        else: Application.put_env(:foreman_server, :command_gateway_module, previous)
    end)

    :ok
  end

  test "POST /api/commands accepts run.steer and derives the run aggregate id" do
    conn =
      build_conn()
      |> post("/api/commands", %{
        type: "run.steer",
        payload: %{run_id: "run-steer-ctl", message_id: "m1", text: "use tabs"}
      })

    assert json_response(conn, 201)["status"] == "accepted"

    assert_receive {:controller_command, %{type: "run.steer", aggregate_id: "run:run-steer-ctl"}}
  end

  test "POST /api/commands rejects run.steer.consume as a system command" do
    conn =
      build_conn()
      |> post("/api/commands", %{
        type: "run.steer.consume",
        payload: %{run_id: "run-steer-ctl", message_ids: ["m1"]}
      })

    assert json_response(conn, 400)["error"] == "invalid_envelope"
    refute_received {:controller_command, _}
  end
end
