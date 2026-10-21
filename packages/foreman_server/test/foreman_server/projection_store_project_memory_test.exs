defmodule ForemanServer.ProjectionStoreProjectMemoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @sha String.duplicate("c", 64)

  defp pid, do: "pm-proj-#{System.unique_integer([:positive])}"

  defp dispatch!(type, project_id, payload) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: type,
        command_id: "#{type}:#{project_id}:#{System.unique_integer([:positive])}",
        aggregate_id: "project_memory:#{project_id}",
        payload: Map.merge(%{project_id: project_id, author_kind: "agent"}, payload)
      })
  end

  defp write!(project_id, name, sha) do
    dispatch!("project.memory.write", project_id, %{
      name: name,
      sha256: sha,
      bytes: 5,
      description: "d-#{name}"
    })
  end

  test "reader returns surviving entries sorted by name, with version bumps; other projects are isolated" do
    p = pid()
    other = pid()
    write!(p, "b", @sha)
    write!(p, "a", @sha)
    write!(p, "a", String.duplicate("d", 64))
    write!(other, "z", @sha)
    dispatch!("project.memory.forget", p, %{name: "b"})

    assert [%{name: "a", version: 2, description: "d-a", author_kind: "agent"}] =
             ProjectionStore.project_memory(p)

    assert [%{name: "z"}] = ProjectionStore.project_memory(other)
    assert ProjectionStore.project_memory(pid()) == []
  end

  test "replayed events keep surviving entries and skips a malformed event" do
    p = pid()
    at = "2026-01-01T00:00:00Z"

    written = fn name, extra ->
      %{
        event_type: "ProjectMemoryWritten",
        payload:
          Map.merge(
            %{
              project_id: p,
              name: name,
              sha256: @sha,
              bytes: 1,
              author_kind: "agent",
              at: at,
              version: 1
            },
            extra
          )
      }
    end

    events = [
      written.("a", %{}),
      written.("b", %{}),
      %{
        event_type: "ProjectMemoryForgotten",
        payload: %{project_id: p, name: "b", author_kind: "agent", at: at}
      },
      %{event_type: "ProjectMemoryWritten", payload: %{project_id: p, name: "broken", bytes: 1}}
    ]

    log =
      capture_log(fn ->
        ProjectionStoreReset.reset!()
        assert :ok = ProjectionStore.apply_events(events)
      end)

    assert log =~ "malformed ProjectMemoryWritten"
    assert [%{name: "a", version: 1}] = ProjectionStore.project_memory(p)
  end
end
