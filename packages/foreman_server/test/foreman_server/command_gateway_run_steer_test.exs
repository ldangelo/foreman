defmodule ForemanServer.CommandGatewayRunSteerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter

  setup do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandRouter, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(CommandRouter) end)
    :ok
  end

  test "dispatch_operator accepts run.steer with the run aggregate id" do
    :meck.expect(CommandRouter, :dispatch, fn command, _timeout ->
      assert command.type == "run.steer"
      assert command.aggregate_id == "run:run-1"
      assert command.payload.text == "use tabs"
      {:ok, %{event_type: "RunSteerQueued"}}
    end)

    assert {:ok, %{event_type: "RunSteerQueued"}} =
             CommandGateway.dispatch_operator(%{
               type: "run.steer",
               command_id: "cmd-steer-1",
               aggregate_id: "run:run-1",
               payload: %{run_id: "run-1", message_id: "m1", text: "use tabs"}
             })

    assert :meck.called(CommandRouter, :dispatch, :_)
  end

  test "run.steer with a mismatched aggregate id is an invalid envelope" do
    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(%{
               type: "run.steer",
               command_id: "cmd-steer-2",
               aggregate_id: "run:other",
               payload: %{run_id: "run-1", message_id: "m1", text: "x"}
             })

    refute :meck.called(CommandRouter, :dispatch, :_)
  end

  test "run.steer.consume stays system-only" do
    assert {:error, {:command_not_allowed, "run.steer.consume"}} =
             CommandGateway.dispatch_operator(%{
               type: "run.steer.consume",
               command_id: "cmd-steer-3",
               aggregate_id: "run:run-1",
               payload: %{run_id: "run-1", message_ids: ["m1"]}
             })

    refute :meck.called(CommandRouter, :dispatch, :_)
  end
end
