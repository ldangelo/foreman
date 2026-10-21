defmodule ForemanServer.Aggregates.ProjectLibraryTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.ProjectLibrary

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)

  defp payload(overrides) do
    Map.merge(
      %{
        project_id: "p",
        entry_id: "docs-1",
        name: "docs",
        kind: "folder",
        file_count: 2,
        bytes: 10,
        manifest_sha256: @sha,
        source: %{"kind" => "upload"},
        skipped_summary: %{"hidden" => 1},
        author_kind: "operator",
        author_ref: "op"
      },
      overrides
    )
  end

  defp cmd(type, overrides \\ %{}), do: %{type: type, payload: payload(overrides)}

  defp apply_cmd(state, type, overrides \\ %{}) do
    {:ok, %{event_type: event_type, payload: p} = event} =
      ProjectLibrary.handle_command(state, cmd(type, overrides))

    assert event.stream_id == "project_library:p"
    ProjectLibrary.apply_event(state, %{event_type: event_type, payload: p})
  end

  test "add emits a metadata-only event" do
    assert {:ok, %{event_type: "ProjectLibraryAdded", payload: p}} =
             ProjectLibrary.handle_command(
               ProjectLibrary.initial_state(),
               cmd("project.library.add")
             )

    assert p.manifest_sha256 == @sha
    assert p.skipped_summary == %{"hidden" => 1}
    refute Map.has_key?(p, :content)
  end

  test "the eleventh folder is {:too_many_folders, 10}; files and produced entries are exempt" do
    state =
      Enum.reduce(1..10, ProjectLibrary.initial_state(), fn n, st ->
        apply_cmd(st, "project.library.add", %{entry_id: "f-#{n}", name: "folder #{n}"})
      end)

    assert {:error, {:too_many_folders, 10}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.add", %{entry_id: "f-11", name: "folder 11"})
             )

    for kind <- ["file", "produced"] do
      assert {:ok, %{event_type: "ProjectLibraryAdded"}} =
               ProjectLibrary.handle_command(
                 state,
                 cmd("project.library.add", %{entry_id: "x-#{kind}", name: kind, kind: kind})
               )
    end
  end

  test "duplicate name and duplicate entry id are distinct errors" do
    state = apply_cmd(ProjectLibrary.initial_state(), "project.library.add")

    assert {:error, {:duplicate_name, "docs"}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.add", %{entry_id: "other"})
             )

    assert {:error, {:duplicate_entry, "docs-1"}} =
             ProjectLibrary.handle_command(state, cmd("project.library.add", %{name: "renamed"}))
  end

  test "replace needs an existing entry, is a no-op for an identical digest, and records the previous digest" do
    empty = ProjectLibrary.initial_state()

    assert {:error, {:not_found, "docs-1"}} =
             ProjectLibrary.handle_command(empty, cmd("project.library.replace"))

    state = apply_cmd(empty, "project.library.add")
    assert {:ok, nil} = ProjectLibrary.handle_command(state, cmd("project.library.replace"))

    assert {:ok, %{event_type: "ProjectLibraryReplaced", payload: p}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.replace", %{manifest_sha256: @sha2})
             )

    assert p.previous_manifest_sha256 == @sha
  end

  test "replace may not take another entry's name" do
    state =
      ProjectLibrary.initial_state()
      |> apply_cmd("project.library.add")
      |> apply_cmd("project.library.add", %{entry_id: "two-1", name: "two"})

    assert {:error, {:duplicate_name, "docs"}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.replace", %{
                 entry_id: "two-1",
                 name: "docs",
                 manifest_sha256: @sha2
               })
             )
  end

  test "remove frees the name and unknown ids are :not_found" do
    state = apply_cmd(ProjectLibrary.initial_state(), "project.library.add")

    assert {:error, {:not_found, "nope"}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.remove", %{entry_id: "nope"})
             )

    state = apply_cmd(state, "project.library.remove")
    assert state.entries == %{}

    assert {:ok, %{event_type: "ProjectLibraryAdded"}} =
             ProjectLibrary.handle_command(
               state,
               cmd("project.library.add", %{entry_id: "docs-2"})
             )
  end

  test "invalid inputs get typed errors" do
    s = ProjectLibrary.initial_state()

    assert {:error, {:invalid_kind, "zip"}} =
             ProjectLibrary.handle_command(s, cmd("project.library.add", %{kind: "zip"}))

    assert {:error, {:invalid_sha256, "nothex"}} =
             ProjectLibrary.handle_command(
               s,
               cmd("project.library.add", %{manifest_sha256: "nothex"})
             )

    assert {:error, {:invalid_author_kind, "bot"}} =
             ProjectLibrary.handle_command(s, cmd("project.library.add", %{author_kind: "bot"}))

    assert {:error, {:missing_or_invalid, :entry_id}} =
             ProjectLibrary.handle_command(s, cmd("project.library.add", %{entry_id: nil}))
  end

  test "an unknown event type never crashes replay" do
    s = ProjectLibrary.initial_state()
    assert ProjectLibrary.apply_event(s, %{event_type: "SomethingNew", payload: %{}}) == s
  end
end
