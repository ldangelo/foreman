defmodule ForemanServer.Coordinator.ConversationStoreTest do
  @moduledoc "The coordinator stream end to end: gateway allowlist, aggregate, projection, rebuild."
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, ProjectionStore}

  setup %{tmp_dir: dir} do
    project_id = "co-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{
          project_id: project_id,
          path: dir,
          config: %{env: %{"API_TOKEN" => "tok-secret-12345"}}
        }
      })

    {:ok, project_id: project_id}
  end

  defp operator(project_id, type, payload, command_id \\ nil) do
    CommandGateway.dispatch_operator(%{
      command_id: command_id || "op-#{System.unique_integer([:positive])}",
      aggregate_id: "coordinator:#{project_id}",
      type: type,
      payload: Map.put(payload, :project_id, project_id)
    })
  end

  defp system(project_id, type, payload, command_id) do
    CommandGateway.dispatch_system(%{
      command_id: command_id,
      aggregate_id: "coordinator:#{project_id}",
      type: type,
      payload: Map.put(payload, :project_id, project_id)
    })
  end

  defp texts(project_id) do
    {:ok, %{messages: messages}} = ProjectionStore.coordinator_conversation(project_id)
    Enum.map(messages, & &1.text)
  end

  test "an operator message lands once; the same message_id is a no-op", %{project_id: p} do
    assert {:ok, _} =
             operator(p, "coordinator.message", %{
               message_id: "m1",
               text: "fix login",
               source: "http"
             })

    assert {:ok, _} =
             operator(p, "coordinator.message", %{
               message_id: "m1",
               text: "fix login",
               source: "http"
             })

    assert {:ok, _} =
             operator(
               p,
               "coordinator.message",
               %{message_id: "m1", text: "changed", source: "http"},
               "op-other"
             )

    assert {:ok,
            %{
              messages: [%{seq: 1, role: "operator", text: "fix login", source: "http"}],
              has_more: false
            }} =
             ProjectionStore.coordinator_conversation(p)

    assert {:ok, events} = EventStore.read_stream_forward("coordinator:#{p}", 0, 100)
    assert length(events) == 1
  end

  test "system-only coordinator commands are refused on the operator path", %{project_id: p} do
    for type <-
          ~w(coordinator.append coordinator.turn.start coordinator.action.record coordinator.turn.complete coordinator.turn.fail) do
      assert {:error, {:command_not_allowed, ^type}} =
               operator(p, type, %{message_id: "x", text: "x"})
    end

    assert texts(p) == []
  end

  test "unknown and archived projects are rejected with typed errors" do
    assert {:error, {:project_not_found, "ghost"}} =
             operator("ghost", "coordinator.message", %{message_id: "m", text: "x", source: "cli"})
  end

  test "an archived project rejects coordinator.message", %{project_id: p} do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "arch-#{p}",
        aggregate_id: "project:#{p}",
        type: "project.archive",
        payload: %{project_id: p}
      })

    assert {:error, {:project_archived, ^p}} =
             operator(p, "coordinator.message", %{message_id: "m", text: "x", source: "cli"})
  end

  test "a mismatched aggregate id is an invalid envelope", %{project_id: p} do
    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(%{
               command_id: "c",
               aggregate_id: "coordinator:other",
               type: "coordinator.message",
               payload: %{project_id: p, message_id: "m", text: "x"}
             })
  end

  test "secrets pasted into a message are redacted before they are stored", %{project_id: p} do
    {:ok, _} =
      operator(p, "coordinator.message", %{
        message_id: "m1",
        text: "my key is tok-secret-12345 ok",
        source: "cli"
      })

    [text] = texts(p)
    refute text =~ "tok-secret-12345"
    assert text =~ "[REDACTED]"

    {:ok, events} = EventStore.read_stream_forward("coordinator:#{p}", 0, 10)
    refute inspect(events) =~ "tok-secret-12345"
  end

  test "turn lifecycle drives the read model, pending projects and health; a rebuild yields the same seqs",
       %{project_id: p} do
    {:ok, _} = operator(p, "coordinator.message", %{message_id: "m1", text: "one", source: "cli"})
    {:ok, _} = operator(p, "coordinator.message", %{message_id: "m2", text: "two", source: "cli"})
    assert p in ProjectionStore.coordinator_pending_projects()

    {:ok, _} =
      system(
        p,
        "coordinator.turn.start",
        %{turn_id: "t1", attempt: 1, trigger_message_ids: ["m1", "m2"]},
        "ts-1"
      )

    assert {:ok, %{status: :turn_open, open_turn: %{turn_id: "t1"}, pending_messages: 2}} =
             ProjectionStore.coordinator_status(p)

    assert p in ProjectionStore.coordinator_pending_projects()

    {:ok, _} =
      system(
        p,
        "coordinator.append",
        %{message_id: "r1", role: "coordinator", kind: "reply", text: "on it", turn_id: "t1"},
        "ap-1"
      )

    {:ok, _} =
      system(p, "coordinator.turn.complete", %{turn_id: "t1", cursor_message_id: "m2"}, "tc-1")

    assert {:ok, %{status: :idle, pending_messages: 0}} = ProjectionStore.coordinator_status(p)
    refute p in ProjectionStore.coordinator_pending_projects()

    before = ProjectionStore.coordinator_state(p)
    :ok = ProjectionStore.rebuild([])
    assert ProjectionStore.coordinator_state(p) == before

    assert {:ok, %{messages: [%{seq: 1}, %{seq: 2}, %{seq: 3, role: "coordinator"}]}} =
             ProjectionStore.coordinator_conversation(p)
  end

  test "after the cursor returns only newer messages", %{project_id: p} do
    for n <- 1..3,
        do:
          {:ok, _} =
            operator(p, "coordinator.message", %{
              message_id: "m#{n}",
              text: "t#{n}",
              source: "cli"
            })

    assert {:ok, %{messages: [%{seq: 3}], next_cursor: 3}} =
             ProjectionStore.coordinator_conversation(p, after: 2)

    assert {:error, :project_not_found} = ProjectionStore.coordinator_conversation("nope")
  end
end
