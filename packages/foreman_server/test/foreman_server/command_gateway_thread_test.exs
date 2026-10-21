defmodule ForemanServer.CommandGatewayThreadTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore}

  defp uid, do: Elixir.EventStore.UUID.uuid4()

  defp command(type, thread_id, overrides \\ %{}) do
    Map.merge(
      %{
        type: type,
        command_id: "op-#{uid()}",
        aggregate_id: "thread:" <> thread_id,
        payload: %{thread_id: thread_id, project_id: "p"}
      },
      overrides
    )
  end

  test "dispatch_operator accepts thread.resolve then thread.reopen and appends both" do
    thread_id = "run:gw-#{uid()}"

    assert {:ok, %{"event_type" => "ThreadResolved"}} =
             CommandGateway.dispatch_operator(command("thread.resolve", thread_id))

    assert {:ok, %{"event_type" => "ThreadReopened"}} =
             CommandGateway.dispatch_operator(command("thread.reopen", thread_id))

    assert {:ok, events} = EventStore.read_stream_forward("thread:" <> thread_id, 0, 99_999)
    assert Enum.map(events, & &1.event_type) == ["ThreadResolved", "ThreadReopened"]
  end

  test "reopening a never-resolved thread surfaces the typed aggregate error" do
    thread_id = "run:gw-#{uid()}"

    assert {:error, {:thread_not_resolved, ^thread_id}} =
             CommandGateway.dispatch_operator(command("thread.reopen", thread_id))
  end

  test "mismatched aggregate_id is an invalid envelope for both types" do
    for type <- ["thread.resolve", "thread.reopen"] do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(
                 command(type, "run:a", %{aggregate_id: "thread:run:other"})
               )
    end
  end

  test "missing thread_id is an invalid envelope" do
    assert {:error, {:invalid_envelope, :missing_thread_id}} =
             CommandGateway.dispatch_operator(
               command("thread.resolve", "run:a", %{payload: %{project_id: "p"}})
             )
  end

  test "the aggregate_id check is per-type: a run aggregate id is refused" do
    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(
               command("thread.resolve", "run:a", %{aggregate_id: "run:a"})
             )
  end
end
