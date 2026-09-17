defmodule ForemanServer.CommandGatewayInboxSendTest do
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter

  setup do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandRouter, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(CommandRouter)
    end)

    :ok
  end

  test "dispatch_operator accepts inbox.send with matching inbox aggregate id" do
    :meck.expect(CommandRouter, :dispatch, fn command, timeout ->
      assert timeout == 5_000
      assert command.type == "inbox.send"
      assert command.aggregate_id == "inbox:run-1"
      assert command.payload.run_id == "run-1"
      assert command.payload.message_id == "msg-1"
      assert command.payload.body == "working"
      {:ok, %{event_type: "InboxMessageAppended"}}
    end)

    assert {:ok, %{event_type: "InboxMessageAppended"}} =
             CommandGateway.dispatch_operator(%{
               type: "inbox.send",
               command_id: "cmd-1",
               aggregate_id: "inbox:run-1",
               payload: %{run_id: "run-1", message_id: "msg-1", body: "working"}
             })

    assert :meck.called(CommandRouter, :dispatch, :_)
  end

  test "dispatch_operator rejects inbox.send aggregate mismatch" do
    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(%{
               type: "inbox.send",
               command_id: "cmd-1",
               aggregate_id: "inbox:other-run",
               payload: %{run_id: "run-1", message_id: "msg-1", body: "working"}
             })

    refute :meck.called(CommandRouter, :dispatch, :_)
  end

  test "dispatch_operator rejects inbox.send missing required payload fields" do
    base = %{
      type: "inbox.send",
      command_id: "cmd-1",
      aggregate_id: "inbox:run-1",
      payload: %{run_id: "run-1", message_id: "msg-1", body: "working"}
    }

    # Truly absent fields (deleted) vs blank fields (present but empty) are
    # both treated as :missing_* by the validator — Map.delete tests absent.
    assert {:error, {:invalid_envelope, :missing_run_id}} =
             base
             |> update_in([:payload], &Map.delete(&1, :run_id))
             |> CommandGateway.dispatch_operator()

    assert {:error, {:invalid_envelope, :missing_message_id}} =
             base
             |> update_in([:payload], &Map.delete(&1, :message_id))
             |> CommandGateway.dispatch_operator()

    assert {:error, {:invalid_envelope, :missing_body}} =
             base
             |> update_in([:payload], &Map.delete(&1, :body))
             |> CommandGateway.dispatch_operator()

    # Blank fields also return :missing_* (present-but-empty is treated the same)
    assert {:error, {:invalid_envelope, :missing_run_id}} =
             put_in(base.payload.run_id, "")
             |> CommandGateway.dispatch_operator()

    refute :meck.called(CommandRouter, :dispatch, :_)
  end

  test "dispatch_operator keeps inbox.delivery.update system-only" do
    assert {:error, {:command_not_allowed, "inbox.delivery.update"}} =
             CommandGateway.dispatch_operator(%{
               type: "inbox.delivery.update",
               command_id: "cmd-1",
               aggregate_id: "inbox:run-1",
               payload: %{run_id: "run-1", message_id: "msg-1", delivery_status: "sent"}
             })

    refute :meck.called(CommandRouter, :dispatch, :_)
  end
end
