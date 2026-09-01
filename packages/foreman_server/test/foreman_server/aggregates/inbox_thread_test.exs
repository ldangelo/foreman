defmodule ForemanServer.Aggregates.InboxThreadTest do
  use ExUnit.Case, async: false
  alias ForemanServer.Aggregates.InboxThread
  alias ForemanServer.Events.{InboxMessageAppended, InboxDeliveryUpdated}

  describe "initial_state" do
    test "starts with empty messages" do
      assert InboxThread.initial_state() == %InboxThread.State{messages: %{}}
    end
  end

  describe "apply_event" do
    test "InboxMessageAppended adds message to state" do
      state = InboxThread.initial_state()
      event = %InboxMessageAppended{
        run_id: "run-123",
        message_id: "msg-1",
        body: "Hello world",
        metadata: %{"phase" => "create-prd"}
      }

      new_state = InboxThread.apply_event(state, event)

      assert Map.has_key?(new_state.messages, "msg-1")
      assert new_state.messages["msg-1"].message_id == "msg-1"
      assert new_state.messages["msg-1"].body == "Hello world"
    end

    test "InboxDeliveryUpdated updates delivery status" do
      state = InboxThread.initial_state()
      append_event = %InboxMessageAppended{
        run_id: "run-123",
        message_id: "msg-1",
        body: "Hello",
        metadata: %{}
      }
      state = InboxThread.apply_event(state, append_event)

      update_event = %InboxDeliveryUpdated{
        run_id: "run-123",
        message_id: "msg-1",
        delivery_status: "delivered",
        metadata: %{"delivered_at" => "2026-09-01"}
      }
      new_state = InboxThread.apply_event(state, update_event)

      assert new_state.messages["msg-1"].delivery_status == "delivered"
    end
  end

  describe "handle_command inbox.send" do
    test "creates InboxMessageAppended event" do
      state = InboxThread.initial_state()
      command = %{
        type: "inbox.send",
        payload: %{
          run_id: "run-123",
          message_id: "msg-1",
          body: "Test message",
          metadata: %{"source" => "test"}
        }
      }

      result = InboxThread.handle_command(state, command)

      assert {:ok, %InboxMessageAppended{
        run_id: "run-123",
        message_id: "msg-1",
        body: "Test message"
      }} = result
    end

    test "rejects duplicate message_id" do
      state_with_msg = %InboxThread.State{
        messages: %{
          "msg-1" => %InboxThread.Message{message_id: "msg-1", body: "First", metadata: %{}}
        }
      }

      command = %{
        type: "inbox.send",
        payload: %{run_id: "run-123", message_id: "msg-1", body: "Duplicate"}
      }
      result = InboxThread.handle_command(state_with_msg, command)

      assert {:error, {:already_exists, :message, "msg-1"}} = result
    end

    test "requires run_id" do
      state = InboxThread.initial_state()
      command = %{
        type: "inbox.send",
        payload: %{message_id: "msg-1", body: "Test"}
      }

      result = InboxThread.handle_command(state, command)

      assert {:error, {:missing_or_invalid, :run_id}} = result
    end
  end

  describe "handle_command inbox.delivery.update" do
    test "creates InboxDeliveryUpdated event" do
      state_with_msg = %InboxThread.State{
        messages: %{
          "msg-1" => %InboxThread.Message{message_id: "msg-1", body: "Test", metadata: %{}}
        }
      }

      update_cmd = %{
        type: "inbox.delivery.update",
        payload: %{run_id: "run-123", message_id: "msg-1", delivery_status: "delivered"}
      }

      result = InboxThread.handle_command(state_with_msg, update_cmd)

      assert {:ok, %InboxDeliveryUpdated{
        run_id: "run-123",
        message_id: "msg-1",
        delivery_status: "delivered"
      }} = result
    end

    test "rejects update for non-existent message" do
      state = InboxThread.initial_state()
      command = %{
        type: "inbox.delivery.update",
        payload: %{run_id: "run-123", message_id: "msg-999", delivery_status: "delivered"}
      }

      result = InboxThread.handle_command(state, command)

      assert {:error, {:not_found, :message, "msg-999"}} = result
    end
  end
end
