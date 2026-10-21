defmodule ForemanServer.Aggregates.ProjectMemoryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ProjectMemory
  alias ForemanServer.Aggregates.ProjectMemory.State
  alias ForemanServer.{CommandGateway, CommandRouter, EventCodec, EventStore}
  alias ForemanServer.Events.{ProjectMemoryForgotten, ProjectMemoryWritten}

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)

  defp write_cmd(overrides \\ %{}) do
    %{
      type: "project.memory.write",
      payload:
        Map.merge(
          %{
            project_id: "p",
            name: "a",
            sha256: @sha,
            bytes: 10,
            author_kind: "agent",
            author_ref: "run-1"
          },
          overrides
        )
    }
  end

  defp forget_cmd(overrides \\ %{}),
    do: %{
      type: "project.memory.forget",
      payload: Map.merge(%{project_id: "p", name: "a", author_kind: "operator"}, overrides)
    }

  defp apply_spec(state, spec), do: ProjectMemory.apply_event(state, spec)

  test "first write emits version 1; same sha is a no-op; changed sha emits version 2" do
    s0 = ProjectMemory.initial_state()

    assert {:ok,
            %{event_type: "ProjectMemoryWritten", stream_id: "project_memory:p", payload: p1}} =
             ProjectMemory.handle_command(s0, write_cmd())

    assert p1.version == 1
    s1 = apply_spec(s0, %{event_type: "ProjectMemoryWritten", payload: p1})

    assert {:ok, nil} = ProjectMemory.handle_command(s1, write_cmd())

    assert {:ok, %{payload: %{version: 2}}} =
             ProjectMemory.handle_command(s1, write_cmd(%{sha256: @sha2}))
  end

  test "forget removes a written name; an unknown name is {:error, {:not_found, name}}" do
    s0 = ProjectMemory.initial_state()
    assert {:error, {:not_found, "a"}} = ProjectMemory.handle_command(s0, forget_cmd())

    {:ok, spec} = ProjectMemory.handle_command(s0, write_cmd())
    s1 = apply_spec(s0, spec)

    assert {:ok, %{event_type: "ProjectMemoryForgotten"} = forgotten} =
             ProjectMemory.handle_command(s1, forget_cmd())

    assert %State{entries: entries} = apply_spec(s1, forgotten)
    assert entries == %{}
  end

  test "each validation failure has its own distinct tuple" do
    s = ProjectMemory.initial_state()

    assert {:error, {:invalid_author_kind, "robot"}} =
             ProjectMemory.handle_command(s, write_cmd(%{author_kind: "robot"}))

    assert {:error, {:missing_or_invalid, :name}} =
             ProjectMemory.handle_command(s, write_cmd(%{name: nil}))

    assert {:error, {:invalid_sha256, "zz"}} =
             ProjectMemory.handle_command(s, write_cmd(%{sha256: "zz"}))

    assert {:error, {:missing_or_invalid, :bytes}} =
             ProjectMemory.handle_command(s, write_cmd(%{bytes: -1}))

    assert {:error, {:missing_or_invalid, :author_ref}} =
             ProjectMemory.handle_command(s, write_cmd(%{author_ref: 5}))
  end

  test "an unknown event type on the stream does not crash replay" do
    s0 = ProjectMemory.initial_state()

    assert ^s0 =
             ProjectMemory.apply_event(s0, %{event_type: "SomethingNew", payload: %{"x" => 1}})
  end

  test "typed events round-trip through EventCodec and carry no content field" do
    written = %{
      "project_id" => "p",
      "name" => "a",
      "sha256" => @sha,
      "bytes" => 3,
      "author_kind" => "agent",
      "at" => "2026-01-01T00:00:00Z"
    }

    assert %ProjectMemoryWritten{version: 1, redactions: 0} =
             EventCodec.decode!("ProjectMemoryWritten", written)

    assert %ProjectMemoryForgotten{name: "a"} =
             EventCodec.decode!("ProjectMemoryForgotten", %{
               "project_id" => "p",
               "name" => "a",
               "author_kind" => "agent",
               "at" => "x"
             })

    refute :content in Map.keys(
             Map.from_struct(%ProjectMemoryWritten{
               project_id: "p",
               name: "a",
               sha256: "s",
               bytes: 1,
               author_kind: "agent",
               at: "t"
             })
           )
  end

  test "the router resolves project_memory:<id> to the aggregate and one command_id persists one event" do
    assert ProjectMemory == CommandRouter.aggregate_module_for("project_memory:p1")
    id = "pm-#{System.unique_integer([:positive])}"

    command =
      Map.merge(write_cmd(%{project_id: id}), %{
        command_id: "cmd-#{id}",
        aggregate_id: "project_memory:#{id}"
      })

    assert {:ok, _} = CommandGateway.dispatch_system(command)
    assert {:ok, _} = CommandGateway.dispatch_system(command)

    assert {:ok, events} = EventStore.read_stream_forward("project_memory:#{id}", 0, 100)
    assert length(events) == 1
  end
end
