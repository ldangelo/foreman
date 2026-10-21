defmodule ForemanServer.LibraryTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, EventStore, Library, ProjectionStore}
  alias ForemanServer.Library.{Entry, Error}

  @operator %{kind: :operator, ref: "op-1"}

  setup %{tmp_dir: dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)
    project_id = "lib-#{System.unique_integer([:positive])}"
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: repo}
      })

    src = Path.join(dir, "src")
    File.mkdir_p!(Path.join(src, "nested"))
    File.write!(Path.join(src, "guide.md"), "# Guide")
    File.write!(Path.join(src, "nested/data.csv"), "a,b")
    File.write!(Path.join(src, ".hidden"), "nope")

    {:ok, project_id: project_id, repo: repo, src: src, dir: dir}
  end

  defp stream_events(project_id) do
    case EventStore.read_stream_forward("project_library:#{project_id}", 0, 1000) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp add_folder!(p, src, name \\ "docs") do
    {:ok, %{entry: entry} = result} = Library.add(p, {:folder, src}, %{name: name}, @operator)
    {entry, result}
  end

  describe "add" do
    test "lands files on disk, appends one event, projects the entry and reports skipped files",
         %{project_id: p, repo: repo, src: src} do
      {entry, result} = add_folder!(p, src)

      assert %Entry{kind: :folder, file_count: 2} = entry
      assert [%{path: ".hidden", reason: :hidden}] = Enum.map(result.skipped, &Map.from_struct/1)

      assert File.read!(Path.join([repo, ".foreman/library", entry.entry_id, "files/guide.md"])) ==
               "# Guide"

      assert [
               %{
                 name: "docs",
                 kind: "folder",
                 skipped_summary: %{"hidden" => 1},
                 author_kind: "operator"
               }
             ] =
               ProjectionStore.project_library(p)

      assert length(stream_events(p)) == 1
    end

    test "event payloads carry metadata only, never file content", %{project_id: p, src: src} do
      add_folder!(p, src)
      [event] = stream_events(p)
      refute inspect(event.data) =~ "# Guide"
    end

    test "uploaded files become a :file entry", %{project_id: p, dir: dir} do
      tmp = Path.join(dir, "upload-tmp")
      File.write!(tmp, "hello")

      assert {:ok,
              %{entry: %Entry{kind: :file, name: "notes", files: [%{path: "sub/notes.txt"}]}}} =
               Library.add(
                 p,
                 {:files, [%{relative_path: "sub/notes.txt", source_path: tmp}]},
                 %{name: "notes", source: %{"kind" => "upload"}},
                 @operator
               )
    end

    test "a duplicate name is rejected before anything is written", %{
      project_id: p,
      repo: repo,
      src: src
    } do
      add_folder!(p, src)

      assert {:error, %Error{code: :duplicate_name}} =
               Library.add(p, {:folder, src}, %{name: "docs"}, @operator)

      assert length(File.ls!(Path.join(repo, ".foreman/library"))) == 1
      assert length(stream_events(p)) == 1
    end

    test "the eleventh folder is :too_many_folders and leaves no files", %{
      project_id: p,
      repo: repo,
      src: src
    } do
      for n <- 1..10, do: add_folder!(p, src, "folder #{n}")

      assert {:error, %Error{code: :too_many_folders, details: %{max: 10}}} =
               Library.add(p, {:folder, src}, %{name: "folder 11"}, @operator)

      assert length(File.ls!(Path.join(repo, ".foreman/library"))) == 10
    end

    test "unknown and archived projects are typed errors", %{project_id: p, src: src} do
      assert {:error, %Error{code: :project_not_found}} =
               Library.add("nope-#{p}", {:folder, src}, %{}, @operator)

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.archive",
          aggregate_id: "project:#{p}",
          payload: %{project_id: p}
        })

      assert {:error, %Error{code: :project_archived}} =
               Library.add(p, {:folder, src}, %{}, @operator)
    end

    test "a rejected add command rolls the disk back (no entry on disk, none in the audit index)",
         %{project_id: p, repo: repo, src: src} do
      # An author ref the aggregate rejects makes the dispatch fail after the files landed.
      bad = %{kind: :operator, ref: 123}

      assert {:error, %Error{code: :dispatch_failed}} =
               Library.add(p, {:folder, src}, %{name: "docs"}, bad)

      library = Path.join(repo, ".foreman/library")
      assert File.ls!(library) == []
      assert stream_events(p) == []
      assert ProjectionStore.project_library(p) == []
    end

    test "a rejected replace restores the previous files", %{project_id: p, repo: repo, src: src} do
      {entry, _} = add_folder!(p, src)
      File.write!(Path.join(src, "guide.md"), "# changed")

      assert {:error, %Error{code: :dispatch_failed}} =
               Library.replace(p, entry.entry_id, {:folder, src}, %{}, %{
                 kind: :operator,
                 ref: 123
               })

      guide = Path.join([repo, ".foreman/library", entry.entry_id, "files/guide.md"])
      assert File.read!(guide) == "# Guide"
      assert length(stream_events(p)) == 1
    end
  end

  describe "replace" do
    test "swaps files, keeps id and name, emits Replaced with the previous digest", %{
      project_id: p,
      src: src,
      repo: repo
    } do
      {entry, _} = add_folder!(p, src)
      File.write!(Path.join(src, "guide.md"), "# Guide v2")

      assert {:ok, %{entry: replaced}} =
               Library.replace(p, entry.entry_id, {:folder, src}, %{}, @operator)

      assert replaced.entry_id == entry.entry_id
      assert replaced.name == "docs"
      assert replaced.manifest_sha256 != entry.manifest_sha256

      assert File.read!(Path.join([repo, ".foreman/library", entry.entry_id, "files/guide.md"])) ==
               "# Guide v2"

      assert [%{manifest_sha256: sha}] = ProjectionStore.project_library(p)
      assert sha == replaced.manifest_sha256
      assert [_, %{event_type: "ProjectLibraryReplaced", data: data}] = stream_events(p)

      assert (data[:previous_manifest_sha256] || data["previous_manifest_sha256"]) ==
               entry.manifest_sha256
    end

    test "A -> B -> A records three events (a deterministic id would drop the third)", %{
      project_id: p,
      src: src
    } do
      {entry, _} = add_folder!(p, src)
      File.write!(Path.join(src, "guide.md"), "B")
      {:ok, _} = Library.replace(p, entry.entry_id, {:folder, src}, %{}, @operator)
      File.write!(Path.join(src, "guide.md"), "# Guide")
      {:ok, back} = Library.replace(p, entry.entry_id, {:folder, src}, %{}, @operator)

      assert back.entry.manifest_sha256 == entry.manifest_sha256
      assert length(stream_events(p)) == 3
    end

    test "an unknown entry is :not_found", %{project_id: p, src: src} do
      assert {:error, %Error{code: :not_found}} =
               Library.replace(p, "nope-1", {:folder, src}, %{}, @operator)
    end
  end

  describe "remove" do
    test "deletes the files and the projection entry", %{project_id: p, src: src, repo: repo} do
      {entry, _} = add_folder!(p, src)
      assert {:ok, %Entry{}} = Library.remove(p, entry.entry_id, @operator)

      assert File.ls!(Path.join(repo, ".foreman/library")) == []
      assert ProjectionStore.project_library(p) == []
      assert {:ok, []} = Library.list(p)
      assert {:error, %Error{code: :not_found}} = Library.remove(p, entry.entry_id, @operator)
    end
  end

  describe "read / list / index / env" do
    test "read returns bytes; traversal and oversize are typed errors", %{project_id: p, src: src} do
      {entry, _} = add_folder!(p, src)
      assert {:ok, "# Guide"} = Library.read(p, entry.entry_id, "guide.md")

      assert {:error, %Error{code: :path_invalid}} =
               Library.read(p, entry.entry_id, "../entry.json")

      assert {:error, %Error{code: :not_found}} = Library.read(p, entry.entry_id, "absent.md")
    end

    test "env and index are empty for an empty library and populated otherwise", %{
      project_id: p,
      src: src,
      repo: repo
    } do
      assert Library.env(p) == %{}
      assert {:ok, ""} = Library.index(p)
      assert Library.env(nil) == %{}

      {entry, _} = add_folder!(p, src)
      expected = Path.join(repo, ".foreman/library")
      assert %{"FOREMAN_LIBRARY_PATH" => path} = Library.env(p)
      assert Path.expand(path) == Path.expand(expected)

      assert {:ok, index} = Library.index(p)
      assert index =~ "$FOREMAN_LIBRARY_PATH/#{entry.entry_id}/files/"
      assert index =~ "guide.md"
      assert index =~ "read-only"
    end

    test "removing the last entry removes the env var again", %{project_id: p, src: src} do
      {entry, _} = add_folder!(p, src)
      {:ok, _} = Library.remove(p, entry.entry_id, @operator)
      assert Library.env(p) == %{}
    end
  end
end
