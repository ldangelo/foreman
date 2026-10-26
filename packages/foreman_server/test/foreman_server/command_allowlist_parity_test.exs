defmodule ForemanServer.CommandAllowlistParityTest do
  @moduledoc """
  The operator command allowlist is ONE list, owned by `ForemanServer.CommandGateway`
  (`operator_types/0`, `command_endpoint_types/0`, `schedule_operator_types/0`,
  `pr_operator_types/0`, `decision_operator_types/0`). `ForemanServerWeb.CommandController`
  reads it rather than keeping a copy. These tests pin the behaviour of both entry
  points against that list: every listed type is accepted by the controller's
  validation and by the gateway's operator path, and a type outside it is rejected by
  both.

  The one documented difference: `inbox.send` is a gateway command sent only by the MCP
  tool `foreman_inbox_send` (it has no HTTP route), so `POST /api/commands` does not accept it.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.CommandGateway

  # Commands that exist but are system-only: they MUST stay off every operator surface.
  @system_only ~w(schedule.mark_fired schedule.skip_fire run.pr.rehold run.steer.consume
                  review.record coordinator.append run.pr.fake)

  # One payload carrying every id field any operator command derives its stream from,
  # so the controller can resolve an aggregate id for every listed type.
  @universal_payload %{
    "project_id" => "p1",
    "task_id" => "t1",
    "run_id" => "r1",
    "thread_id" => "th1",
    "schedule_id" => "s1",
    "tool_call_id" => "tc1",
    "question_id" => "q1"
  }

  defmodule RecordingGateway do
    @moduledoc false
    def dispatch_operator(command) do
      send(Application.fetch_env!(:foreman_server, :allowlist_probe_pid), {:dispatched, command})
      {:ok, nil}
    end
  end

  setup do
    Application.put_env(:foreman_server, :command_gateway_module, RecordingGateway)
    Application.put_env(:foreman_server, :allowlist_probe_pid, self())

    on_exit(fn ->
      Application.delete_env(:foreman_server, :command_gateway_module)
      Application.delete_env(:foreman_server, :allowlist_probe_pid)
    end)
  end

  test "the lists nest: schedule and PR types are endpoint types, and only inbox.send is gateway-only" do
    endpoint = CommandGateway.command_endpoint_types()

    assert CommandGateway.schedule_operator_types() -- endpoint == []
    refute Enum.empty?(CommandGateway.schedule_operator_types())
    assert CommandGateway.pr_operator_types() -- endpoint == []
    refute Enum.empty?(CommandGateway.pr_operator_types())

    assert CommandGateway.operator_types() -- endpoint == ["inbox.send"]
    assert endpoint -- CommandGateway.operator_types() == []
    assert Enum.uniq(CommandGateway.operator_types()) == CommandGateway.operator_types()

    for type <- @system_only, do: refute(type in CommandGateway.operator_types(), type)
  end

  test "CommandGateway.dispatch_operator accepts every listed type and rejects the rest" do
    # No aggregate id and an empty payload: an accepted type is rejected as a malformed
    # envelope before anything is dispatched, a type outside the list is rejected as
    # not allowed.
    accepted = CommandGateway.operator_types() ++ CommandGateway.decision_operator_types()

    for type <- accepted do
      assert {:error, {:invalid_envelope, _}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "probe-#{type}",
                 type: type,
                 aggregate_id: nil,
                 payload: %{}
               }),
             type
    end

    for type <- @system_only do
      assert {:error, {:command_not_allowed, ^type}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "probe-#{type}",
                 type: type,
                 aggregate_id: nil,
                 payload: %{}
               })
    end
  end

  test "CommandController accepts every endpoint type and decision type, and rejects the rest" do
    accepted = CommandGateway.command_endpoint_types() ++ CommandGateway.decision_operator_types()

    for type <- accepted do
      conn =
        post(build_conn(), "/api/commands", %{"type" => type, "payload" => @universal_payload})

      assert json_response(conn, 201), type
      assert_received {:dispatched, %{type: ^type, aggregate_id: aggregate_id}}
      assert is_binary(aggregate_id) and aggregate_id != "", type
    end

    for type <- ["inbox.send" | @system_only] do
      conn =
        post(build_conn(), "/api/commands", %{"type" => type, "payload" => @universal_payload})

      assert %{"error" => "invalid_envelope"} = json_response(conn, 400)
      refute_received {:dispatched, _}
    end
  end
end
