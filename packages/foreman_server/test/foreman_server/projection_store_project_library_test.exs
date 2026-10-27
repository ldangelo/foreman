defmodule ForemanServer.ProjectionStoreProjectLibraryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.{ProjectionStoreReset, ThrowawayProjectionStore}

  @sha String.duplicate("c", 64)
  @sha2 String.duplicate("d", 64)
  @at "2026-01-01T00:00:00Z"

  test "replay keeps surviving entries and applies replace and remove" do
    p = "lib-proj-#{System.unique_integer([:positive])}"

    base = base_payload(p)

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
      }
    ]

    ProjectionStoreReset.reset!()
    assert :ok = ProjectionStore.apply_events(events)

    assert [%{entry_id: "a-1", manifest_sha256: @sha2, bytes: 20, kind: "folder"}] =
             ProjectionStore.project_library(p)

    assert ProjectionStore.project_library("someone-else") == []
  end

  # AGENTS.md 5.2: `Aggregates.ProjectLibrary` validates every field the projection reads, so a
  # malformed library event in the log means the aggregate was bypassed. Skipping it would leave
  # `project_library/1` silently disagreeing with the audit trail (also after replay): the fold
  # raises, like `PrAssociated`, instead of returning the state unchanged.
  describe "a malformed library event fails loudly instead of being skipped" do
    test "an event without its required keys raises the codec's ArgumentError" do
      p = unique_project()

      exit_reason =
        ThrowawayProjectionStore.crash_on_apply!([
          %{event_type: "ProjectLibraryAdded", payload: %{project_id: p, name: "broken"}}
        ])

      assert {%ArgumentError{message: message}, _stack} = exit_reason
      assert message =~ "ProjectLibraryAdded"
      assert message =~ "missing enforced keys"
    end

    for {type, extra} <- [
          {"ProjectLibraryAdded", %{}},
          {"ProjectLibraryReplaced", %{previous_manifest_sha256: @sha2}}
        ] do
      test "#{type} that decodes but names no entry raises" do
        p = unique_project()
        payload = Map.merge(base_payload(p), %{entry_id: "", name: "n"})
        payload = Map.merge(payload, unquote(Macro.escape(extra)))

        exit_reason =
          ThrowawayProjectionStore.crash_on_apply!([
            %{event_type: unquote(type), payload: payload}
          ])

        assert {%ArgumentError{message: message}, _stack} = exit_reason
        assert message =~ "ProjectionStore: #{unquote(type)} with unusable"
      end
    end

    test "ProjectLibraryRemoved that names no entry raises" do
      p = unique_project()

      exit_reason =
        ThrowawayProjectionStore.crash_on_apply!([
          %{
            event_type: "ProjectLibraryRemoved",
            payload: %{project_id: p, entry_id: "", name: "b", author_kind: "operator", at: @at}
          }
        ])

      assert {%ArgumentError{message: message}, _stack} = exit_reason
      assert message =~ "ProjectionStore: ProjectLibraryRemoved with unusable"
    end

    test "ProjectLibraryRemoved without its required keys raises the codec's ArgumentError" do
      p = unique_project()

      exit_reason =
        ThrowawayProjectionStore.crash_on_apply!([
          %{event_type: "ProjectLibraryRemoved", payload: %{project_id: p}}
        ])

      assert {%ArgumentError{message: message}, _stack} = exit_reason
      assert message =~ "ProjectLibraryRemoved"
    end
  end

  defp unique_project, do: "lib-proj-#{System.unique_integer([:positive])}"

  defp base_payload(project_id) do
    %{
      project_id: project_id,
      kind: "folder",
      file_count: 2,
      bytes: 9,
      manifest_sha256: @sha,
      author_kind: "operator",
      at: @at
    }
  end
end
