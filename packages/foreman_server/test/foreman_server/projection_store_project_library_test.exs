defmodule ForemanServer.ProjectionStoreProjectLibraryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @sha String.duplicate("c", 64)
  @sha2 String.duplicate("d", 64)
  @at "2026-01-01T00:00:00Z"

  test "replay keeps surviving entries, applies replace, and skips a malformed event" do
    p = "lib-proj-#{System.unique_integer([:positive])}"

    base = %{
      project_id: p,
      kind: "folder",
      file_count: 2,
      bytes: 9,
      manifest_sha256: @sha,
      author_kind: "operator",
      at: @at
    }

    events = [
      %{
        event_type: "ProjectLibraryAdded",
        payload: Map.merge(base, %{entry_id: "b-1", name: "b"})
      },
      %{
        event_type: "ProjectLibraryAdded",
        payload: Map.merge(base, %{entry_id: "a-1", name: "a"})
      },
      %{
        event_type: "ProjectLibraryReplaced",
        payload:
          Map.merge(base, %{
            entry_id: "a-1",
            name: "a",
            manifest_sha256: @sha2,
            previous_manifest_sha256: @sha,
            bytes: 20
          })
      },
      %{
        event_type: "ProjectLibraryRemoved",
        payload: %{project_id: p, entry_id: "b-1", name: "b", author_kind: "operator", at: @at}
      },
      %{event_type: "ProjectLibraryAdded", payload: %{project_id: p, name: "broken"}}
    ]

    log =
      capture_log(fn ->
        ProjectionStoreReset.reset!()
        assert :ok = ProjectionStore.apply_events(events)
      end)

    assert log =~ "malformed ProjectLibraryAdded"

    assert [%{entry_id: "a-1", manifest_sha256: @sha2, bytes: 20, kind: "folder"}] =
             ProjectionStore.project_library(p)

    assert ProjectionStore.project_library("someone-else") == []
  end
end
