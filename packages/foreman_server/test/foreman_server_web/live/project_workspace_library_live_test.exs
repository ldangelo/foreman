defmodule ForemanServerWeb.ProjectWorkspaceLibraryLiveTest do
  # foreman-8ervf: the workspace's Library tab adds files and folders, replaces an entry's
  # files, downloads a file and removes an entry. Every write goes through `Library.add/4`,
  # `Library.replace/5` or `Library.remove/3`, the calls behind the HTTP routes and the CLI,
  # so names, paths, counts and sizes follow the library's rules, not the browser's; the
  # whole-add cap `upload_max_bytes`, which LiveView does not enforce, is held by the page.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, EventStore, Library, ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset}

  @endpoint ForemanServerWeb.Endpoint
  @token "workspace-library-live-token"
  @operator %{kind: :operator, ref: "test"}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # library entries are locked read-only on disk; let ExUnit delete the tmp dir
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)

    Eventually.put_env_for_test(:foreman_server, :api_bearer_token, @token)
    Eventually.put_env_for_test(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    id = "wslib-#{System.unique_integer([:positive])}"
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: repo, name: "Library Demo"})

    {:ok, id: id, dir: dir}
  end

  defp mount_view(id) do
    {:ok, view, html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")
    {view, html}
  end

  defp pick(view, files),
    do: file_input(view, "#library-form", :library, files)

  defp upload_all(input, files),
    do: for(%{name: name} <- files, do: render_upload(input, name))

  defp submit(view, name),
    do: view |> form("#library-form", %{"name" => name}) |> render_submit()

  defp file(name, content), do: %{name: name, content: content, type: "application/octet-stream"}

  # Adds an entry the way the HTTP route and the CLI do (a source file on disk).
  defp seed_entry(id, dir, name, content) do
    source = Path.join(dir, "seed-#{System.unique_integer([:positive])}.txt")
    File.write!(source, content)

    assert {:ok, %{entry: entry}} =
             Library.add(
               id,
               {:files, [%{relative_path: "seed.txt", source_path: source}]},
               %{name: name},
               @operator
             )

    entry
  end

  defp seed_files(id, dir, name, files) do
    sources =
      for {rel, content} <- files do
        source = Path.join(dir, "seed-#{System.unique_integer([:positive])}")
        File.write!(source, content)
        %{relative_path: rel, source_path: source}
      end

    assert {:ok, %{entry: entry}} = Library.add(id, {:files, sources}, %{name: name}, @operator)
    entry
  end

  # A folder entry, added the way an uploaded folder is (paths below the folder).
  defp seed_folder(id, dir, name, files) do
    sources =
      for {rel, content} <- files do
        source = Path.join(dir, "seed-#{System.unique_integer([:positive])}")
        File.write!(source, content)
        %{relative_path: rel, source_path: source}
      end

    assert {:ok, %{entry: entry}} =
             Library.add(id, {:folder_files, sources}, %{name: name}, @operator)

    entry
  end

  # A thread-produced entry (owned by its run), registered the way the collector does.
  defp seed_produced(id, dir, run_id) do
    repo = Path.join(dir, "repo")
    source = Path.join(repo, "out-#{System.unique_integer([:positive])}.md")
    File.write!(source, "output")

    assert {:ok, %{entry: entry}} =
             Library.register_produced(
               id,
               run_id,
               [%{relative_path: "out.md", source_path: source}],
               allowed_roots: [repo, dir]
             )

    entry
  end

  # `config :foreman_server, :library` for this test, restored afterwards: the shipped
  # config with `overrides` on top. ONE call per test (`put_env_for_test/3` keeps the
  # original of a key only on its first call).
  defp library_config(overrides) do
    current = Application.get_env(:foreman_server, :library, [])
    Eventually.put_env_for_test(:foreman_server, :library, Keyword.merge(current, overrides))
  end

  # A file picked as part of the folder `root`: the browser reports `<root>/<rel>`.
  defp folder_file(root, rel, content) do
    %{
      name: Path.basename(rel),
      relative_path: "#{root}/#{rel}",
      content: content,
      type: "application/octet-stream"
    }
  end

  # One `file_input` per file. LiveViewTest's upload client is ONE process per `file_input`
  # call: consuming an entry closes its channel, which stops that client and every sibling
  # channel it owns, so several entries can only be consumed in one event when each has
  # its own client (each channel stands alone in a browser). Entry names must be unique.
  defp upload_each(view, form, upload, files) do
    for file <- files do
      input = file_input(view, form, upload, [file])
      render_upload(input, file.name)
      input
    end
  end

  defp submit_folder(view, name),
    do: view |> form("#library-folder-form", %{"name" => name}) |> render_submit()

  defp submit_replace(view), do: view |> form("#library-replace-form") |> render_submit()

  defp open_replace(view, entry) do
    view
    |> element("#library-entry-#{entry.entry_id} button", "Replace #{entry.name}")
    |> render_click()
  end

  describe "the upload form" do
    test "is labelled and states the library's limits", %{id: id} do
      {view, html} = mount_view(id)

      assert html =~ "Up to 100 files per add, 480 MiB each."
      assert has_element?(view, "#library-form legend", "Add files")
      assert has_element?(view, ~s(#library-form label[for="library_name"]), "Name (optional)")
      assert has_element?(view, ~s(#library-form input#library_name[name="name"]))
      # the file input is named by its label (for/id) and described by the limits text
      [_, input_id] = Regex.run(~r/<label for="([^"]+)">Files<\/label>/, html)

      assert has_element?(
               view,
               ~s(#library-form input[type="file"][id="#{input_id}"][aria-describedby="library-limits"])
             )

      assert has_element?(view, "#library-limits")
    end

    test "limits follow the library config", %{id: id} do
      Eventually.put_env_for_test(:foreman_server, :library,
        max_files_per_add: 3,
        max_file_bytes: 2 * 1024
      )

      {_view, html} = mount_view(id)
      assert html =~ "Up to 3 files per add, 2 KiB each."
    end
  end

  describe "adding files" do
    test "an uploaded file becomes a library entry through Library.add; the tab lists it", %{
      id: id
    } do
      {view, _} = mount_view(id)
      files = [file("guide.md", "# Guide")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      assert render(view) =~ "guide.md"
      html = submit(view, "kit")

      assert html =~ "Added kit to the library (1 file)."

      assert [%{name: "kit", kind: :file, file_count: 1, source: %{"kind" => "upload"}} = entry] =
               list!(id)

      assert {:ok, "# Guide"} = Library.read(id, entry.entry_id, "guide.md")

      # the audit command was dispatched: the projection knows the entry too
      assert [%{name: "kit", entry_id: entry_id}] = ProjectionStore.project_library(id)
      assert entry_id == entry.entry_id

      # metadata only: name, kind, count and size; never file content
      assert has_element?(view, "#library-list li", "kit")
      assert has_element?(view, "#library-list li", "1 file")
      refute render(view) =~ "# Guide"

      # the consumed selection leaves the form (and the name box is cleared)
      Eventually.await(fn -> not has_element?(view, "#library-selected") end)
      assert has_element?(view, ~s(#library_name[value=""]))
    end

    # LiveViewTest's upload client closes every sibling upload channel as soon as the
    # first entry is consumed, so consuming two entries in one event cannot be driven
    # through the view in a test (a plain `{:ok, _}` consume crashes the same way).
    # The action the form calls is tested directly with two files instead.
    test "several files are added as ONE entry (the action behind the form)", %{id: id, dir: dir} do
      sources =
        for {name, content} <- [{"guide.md", "# Guide"}, {"data.csv", "a,b"}] do
          path = Path.join(dir, "src-#{name}")
          File.write!(path, content)
          %{relative_path: name, source_path: path}
        end

      assert {:ok, "Added kit to the library (2 files)."} =
               ForemanServerWeb.Workspace.Actions.library_add(id, sources, "kit")

      assert [%{name: "kit", kind: :file, file_count: 2} = entry] = list!(id)
      assert {:ok, "# Guide"} = Library.read(id, entry.entry_id, "guide.md")
      assert {:ok, "a,b"} = Library.read(id, entry.entry_id, "data.csv")
    end

    test "a blank name is derived from a single file", %{id: id} do
      {view, _} = mount_view(id)
      files = [file("release notes.md", "x")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      assert submit(view, "  ") =~ "Added release notes to the library (1 file)."
      assert [%{name: "release notes"}] = list!(id)
    end

    test "submitting with nothing chosen is refused and nothing is written", %{id: id} do
      {view, _} = mount_view(id)
      assert submit(view, "kit") =~ "Choose at least one file to add."
      assert list!(id) == []
    end

    test "a refused add (taken name) keeps the uploaded selection for another try", %{
      id: id,
      dir: dir
    } do
      seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)

      files = [file("new.txt", "new")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      html = submit(view, "kit")
      assert html =~ "Could not add:"
      assert html =~ "already exists"
      assert html =~ "new.txt"
      assert has_element?(view, "#library-selected li", "new.txt")
      assert [_] = list!(id)

      # same selection, a free name: no second upload needed
      assert submit(view, "kit2") =~ "Added kit2 to the library (1 file)."
      assert Enum.sort(Enum.map(list!(id), & &1.name)) == ["kit", "kit2"]
    end

    test "the library's name rule applies", %{id: id} do
      {view, _} = mount_view(id)
      files = [file("a.txt", "a")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      html = submit(view, "bad/name!")
      assert html =~ "entry name must match"
      assert list!(id) == []
    end

    test "the library's path rule applies: a hostile file name is refused, nothing is written", %{
      id: id,
      dir: dir
    } do
      {view, _} = mount_view(id)
      files = [file("../evil.txt", "owned")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      html = submit(view, "kit")
      assert html =~ "invalid library path"
      assert list!(id) == []
      refute File.exists?(Path.join(dir, "evil.txt"))
      refute File.exists?(Path.join([dir, "repo", ".foreman", "evil.txt"]))
    end

    test "the library's count rule applies at the server whatever the form allowed", %{id: id} do
      # the LiveView allows 2 entries; Library.add (limit 1 here) is checked on its own
      Eventually.put_env_for_test(:foreman_server, :library, max_files_per_add: 2)
      {view, _} = mount_view(id)
      Application.put_env(:foreman_server, :library, max_files_per_add: 1)

      files = [file("a.txt", "a"), file("b.txt", "b")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      html = submit(view, "kit")
      assert html =~ "at most 1 files per add (got 2)"
      assert list!(id) == []
    end

    test "too many files are refused by the form before anything is sent to the library", %{
      id: id
    } do
      Eventually.put_env_for_test(:foreman_server, :library, max_files_per_add: 2)
      {view, _} = mount_view(id)

      files = [file("a.txt", "a"), file("b.txt", "b"), file("c.txt", "c")]
      input = pick(view, files)

      # LiveViewTest answers a refused preflight with the error, the page shows it
      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "a.txt")
      assert render(view) =~ "Too many files"

      html = submit(view, "kit")
      assert html =~ "cancel the files marked with an error"
      assert list!(id) == []
    end

    test "a file over the per-file limit is refused by the form", %{id: id} do
      Eventually.put_env_for_test(:foreman_server, :library, max_file_bytes: 8)
      {view, _} = mount_view(id)

      files = [file("big.bin", String.duplicate("x", 9))]
      input = pick(view, files)

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.bin")
      assert render(view) =~ "This file is over the per-file limit."
      assert has_element?(view, "#library-selected li", "big.bin")
      assert submit(view, "kit") =~ "cancel the files marked with an error"
      assert list!(id) == []
    end

    test "an archived project refuses the add with the library's reason", %{id: id} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "archive-#{id}",
                 type: "project.archive",
                 aggregate_id: "project:#{id}",
                 payload: %{project_id: id}
               })

      {view, _} = mount_view(id)
      files = [file("a.txt", "a")]
      files |> then(&pick(view, &1)) |> upload_all(files)

      assert submit(view, "kit") =~ "Could not add: project is archived"
    end

    test "a selected file can be cancelled; a stale cancel is a no-op", %{id: id} do
      {view, _} = mount_view(id)
      files = [file("a.txt", String.duplicate("a", 100))]
      input = pick(view, files)
      render_upload(input, "a.txt", 10)

      assert has_element?(view, ~s(#library-selected button[aria-label="Cancel upload of a.txt"]))

      view |> element("#library-selected button", "Cancel upload") |> render_click()
      refute has_element?(view, "#library-selected")

      # the entry is gone; clicking its (stale) cancel again must not crash the view
      assert render_click(view, "library_cancel_upload", %{"ref" => "0"}) =~ "Library"
      assert Process.alive?(view.pid)
    end
  end

  describe "removing files" do
    test "needs a confirm step, then removes the entry from disk and the audit index", %{
      id: id,
      dir: dir
    } do
      entry = seed_entry(id, dir, "old", "content")
      {view, _} = mount_view(id)

      assert has_element?(view, "#library-list li", "old")
      view |> element("#library-list button", "Remove old") |> render_click()

      # first click only asks: nothing is removed yet
      assert has_element?(view, "#library-list li", "old")
      assert has_element?(view, "#library-list button", "Confirm remove old")
      assert {:ok, [_]} = Library.list(id)

      # Cancel backs out
      view |> element("#library-list button", "Cancel") |> render_click()
      refute has_element?(view, "#library-list button", "Confirm remove old")
      assert {:ok, [_]} = Library.list(id)

      view |> element("#library-list button", "Remove old") |> render_click()
      html = view |> element("#library-list button", "Confirm remove old") |> render_click()

      assert html =~ "Removed old from the library."
      refute has_element?(view, "#library-list")
      assert list!(id) == []
      assert {:error, %{code: :not_found}} = Library.get(id, entry.entry_id)
      assert ProjectionStore.project_library(id) == []
    end

    test "an entry that is already gone is reported, not crashed on", %{id: id, dir: dir} do
      # The page has to still show the entry when it is clicked below. The removal broadcasts a
      # projection event and the page refreshes `coalesce_ms` later (20 ms in `setup`), which on
      # a loaded host is over before the first click: no refresh in between, as for a resent
      # removal in `ProjectSettingsLiveTest`.
      Application.put_env(:foreman_server, :workspace, coalesce_ms: 60_000)
      entry = seed_entry(id, dir, "old", "content")
      {view, _} = mount_view(id)

      # removed elsewhere (CLI, HTTP) after this page loaded
      assert {:ok, _} = Library.remove(id, entry.entry_id, @operator)

      view |> element("#library-list button", "Remove old") |> render_click()
      html = view |> element("#library-list button", "Confirm remove old") |> render_click()

      assert html =~ "That library entry no longer exists."
      assert Process.alive?(view.pid)
    end

    test "a forged entry id is refused and touches nothing", %{id: id, dir: dir} do
      seed_entry(id, dir, "keep", "content")
      {view, _} = mount_view(id)

      for forged <- ["nope", "../../etc", "..", ""] do
        assert render_click(view, "library_remove", %{"entry-id" => forged}) =~
                 "That library entry no longer exists."
      end

      assert [%{name: "keep"}] = list!(id)
    end
  end

  describe "adding a folder" do
    test "the folder form is labelled, takes a directory and states the folder rules", %{id: id} do
      {view, html} = mount_view(id)

      assert html =~
               "Up to 100 files and 200 MiB per folder; hidden files, node_modules and files over 30 MiB are left out. At most 512 MiB in all."

      assert has_element?(view, "#library-folder-form legend", "Add a folder")

      assert has_element?(
               view,
               ~s(#library-folder-form label[for="library_folder_name"]),
               "Name (optional)"
             )

      [_, input_id] = Regex.run(~r/<label for="([^"]+)">Folder<\/label>/, html)

      assert has_element?(
               view,
               ~s(#library-folder-form input[type="file"][id="#{input_id}"][webkitdirectory][aria-describedby="library-folder-limits"])
             )

      # only the folder form picks a directory; the files form still picks files
      refute has_element?(view, "#library-form input[webkitdirectory]")
    end

    test "a folder becomes ONE folder entry named after it, paths kept, hidden files skipped and reported",
         %{id: id} do
      {view, _} = mount_view(id)

      files = [
        folder_file("kit", "docs/a.md", "# Chapter A"),
        folder_file("kit", "b.txt", "bee"),
        folder_file("kit", ".secret", "SECRET=1")
      ]

      upload_each(view, "#library-folder-form", :library_folder, files)

      # the selection lists the paths as the browser reported them
      assert has_element?(view, "#library-folder-selected li", "kit/docs/a.md")

      html = submit_folder(view, "")
      assert html =~ "Added kit to the library (2 files; 1 skipped: hidden)."

      assert [%{name: "kit", kind: :folder, file_count: 2, source: %{"kind" => "upload"}} = entry] =
               list!(id)

      # the folder's own name is the entry's name, not a path segment
      assert entry.files |> Enum.map(& &1.path) |> Enum.sort() == ["b.txt", "docs/a.md"]
      assert {:ok, "# Chapter A"} = Library.read(id, entry.entry_id, "docs/a.md")
      assert {:ok, "bee"} = Library.read(id, entry.entry_id, "b.txt")
      assert {:error, %{code: :not_found}} = Library.read(id, entry.entry_id, ".secret")

      # the audit index knows what was left out
      assert [%{kind: "folder", skipped_summary: %{"hidden" => 1}}] =
               ProjectionStore.project_library(id)

      assert has_element?(view, "#library-list li", "kit")
      refute render(view) =~ "# Chapter A"

      # the consumed selection leaves the form and the name box is cleared
      Eventually.await(fn -> not has_element?(view, "#library-folder-selected") end)
      assert has_element?(view, ~s(#library_folder_name[value=""]))
    end

    test "every skip reason is counted in the notice", %{id: id} do
      {view, _} = mount_view(id)

      files = [
        folder_file("kit", "a.md", "a"),
        folder_file("kit", ".env", "SECRET=1"),
        folder_file("kit", "node_modules/dep/index.js", "x")
      ]

      upload_each(view, "#library-folder-form", :library_folder, files)

      assert submit_folder(view, "") =~
               "Added kit to the library (1 file; 2 skipped: 1 hidden, 1 node_modules)."
    end

    test "a typed name wins over the folder's own name", %{id: id} do
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [folder_file("kit", "a.md", "a")])

      assert submit_folder(view, "handbook") =~ "Added handbook to the library (1 file)."
      assert [%{name: "handbook", kind: :folder}] = list!(id)
    end

    test "a folder whose name is not a valid entry name is named by the library", %{id: id} do
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [
        folder_file("my.docs", "a.md", "a"),
        folder_file("my.docs", "sub/b.md", "b")
      ])

      assert submit_folder(view, "") =~ "Added folder to the library (2 files)."
      assert [%{name: "folder", kind: :folder} = entry] = list!(id)
      assert entry.files |> Enum.map(& &1.path) |> Enum.sort() == ["a.md", "sub/b.md"]
    end

    test "a refused folder add (taken name) keeps the selection for another try", %{
      id: id,
      dir: dir
    } do
      seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [
        folder_file("kit", "a.md", "new")
      ])

      html = submit_folder(view, "")
      assert html =~ "Could not add:"
      assert html =~ "already exists"
      assert has_element?(view, "#library-folder-selected li", "kit/a.md")
      assert [_] = list!(id)

      # same selection, a free name: no second upload needed
      assert submit_folder(view, "kit2") =~ "Added kit2 to the library (1 file)."
      assert Enum.sort(Enum.map(list!(id), & &1.name)) == ["kit", "kit2"]
    end

    test "a folder with nothing eligible is refused with the library's reason and keeps the selection",
         %{id: id} do
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [
        folder_file("kit", ".env", "SECRET=1"),
        folder_file("kit", ".git/HEAD", "ref")
      ])

      assert submit_folder(view, "") =~ "Could not add: folder has no eligible files"
      assert has_element?(view, "#library-folder-selected li", "kit/.env")
      assert list!(id) == []
    end

    test "more files than a folder may hold are refused by the form, which points at the CLI",
         %{id: id} do
      library_config(folder_max_files: 2)
      {view, _} = mount_view(id)

      files = [
        folder_file("kit", "a.md", "a"),
        folder_file("kit", "b.md", "b"),
        folder_file("kit", "c.md", "c")
      ]

      input = file_input(view, "#library-folder-form", :library_folder, files)
      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "a.md")

      html = render(view)
      assert html =~ "More than 2 files are selected, hidden files and node_modules included."
      assert html =~ "foreman project library add"

      assert submit_folder(view, "") =~ "clear the selection and choose again"
      assert list!(id) == []

      # one button drops the whole selection
      view |> element("#library-folder-form button", "Clear selection") |> render_click()
      refute has_element?(view, "#library-folder-selected")
      refute has_element?(view, "#library-folder-form button", "Clear selection")
    end

    test "a file over the per-file limit is refused by the form", %{id: id} do
      library_config(max_file_bytes: 8)
      {view, _} = mount_view(id)

      input =
        file_input(view, "#library-folder-form", :library_folder, [
          folder_file("kit", "big.bin", String.duplicate("x", 9))
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.bin")

      assert has_element?(
               view,
               "#library-folder-selected li",
               "This file is over the per-file limit."
             )

      assert submit_folder(view, "") =~ "clear the selection and choose again"
      assert list!(id) == []
    end

    test "a hostile relative path is refused by the library and nothing is written", %{
      id: id,
      dir: dir
    } do
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [
        folder_file("..", "evil.txt", "owned")
      ])

      assert submit_folder(view, "") =~ "invalid library path"
      assert list!(id) == []
      refute File.exists?(Path.join(dir, "evil.txt"))
      refute File.exists?(Path.join([dir, "repo", ".foreman", "evil.txt"]))
      assert has_element?(view, "#library-folder-selected li", "../evil.txt")
    end

    test "submitting with no folder chosen is refused and nothing is written", %{id: id} do
      {view, _} = mount_view(id)
      assert submit_folder(view, "kit") =~ "Choose a folder to add."
      assert list!(id) == []
    end
  end

  describe "the whole-add cap (upload_max_bytes)" do
    test "the limits sentences state the cap and the per-file limit never exceeds it", %{id: id} do
      {_view, html} = mount_view(id)
      assert html =~ "Up to 100 files per add, 480 MiB each. At most 512 MiB in all."
    end

    test "a lowered cap clamps the per-file limit of every form and is shown in #library-limits",
         %{id: id} do
      library_config(upload_max_bytes: 8)
      {view, html} = mount_view(id)

      assert html =~ "Up to 100 files per add, 8 B each. At most 8 B in all."
      assert has_element?(view, "#library-limits", "8 B each. At most 8 B in all.")
      assert has_element?(view, "#library-folder-limits", "At most 8 B in all.")

      # a file within max_file_bytes but over the cap is refused by the form, in every form
      for {form, upload} <- [
            {"#library-form", :library},
            {"#library-folder-form", :library_folder}
          ] do
        input = file_input(view, form, upload, [file("big.bin", String.duplicate("x", 9))])
        assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.bin")
      end

      assert render(view) =~ "This file is over the per-file limit."
      assert list!(id) == []
    end

    test "the per-file limit stays the library's when that is the lower one", %{id: id} do
      library_config(max_file_bytes: 5, upload_max_bytes: 100)
      {_view, html} = mount_view(id)
      assert html =~ "Up to 100 files per add, 5 B each. At most 100 B in all."
    end

    test "files that add up to more than the cap show an alert naming both sizes and disable Add",
         %{id: id} do
      library_config(max_files_per_add: 5, upload_max_bytes: 10)
      {view, _} = mount_view(id)

      # 6 B and 6 B: each within the cap, together 12 B
      upload_each(view, "#library-form", :library, [
        file("a.txt", "aaaaaa"),
        file("b.txt", "bbbbbb")
      ])

      assert has_element?(
               view,
               ~s(#library-form [role="alert"]),
               "These files add up to 12 B; at most 10 B can be added at once."
             )

      assert has_element?(view, ~s(#library-form button[type="submit"][disabled]))

      # dropping one file brings the selection back under the cap
      view
      |> element(~s(#library-selected button[aria-label="Cancel upload of b.txt"]))
      |> render_click()

      refute render(view) =~ "add up to"
      refute has_element?(view, ~s(#library-form button[type="submit"][disabled]))
      assert submit(view, "kit") =~ "Added kit to the library (1 file)."
    end

    test "a submit that arrives anyway (the button is only disabled) is refused and keeps the selection",
         %{id: id} do
      library_config(max_files_per_add: 5, upload_max_bytes: 10)
      {view, _} = mount_view(id)

      upload_each(view, "#library-form", :library, [
        file("a.txt", "aaaaaa"),
        file("b.txt", "bbbbbb")
      ])

      html = submit(view, "kit")
      assert html =~ "These files add up to 12 B; at most 10 B can be added at once."
      assert list!(id) == []
      assert ProjectionStore.project_library(id) == []
      assert has_element?(view, "#library-selected li", "a.txt")
      assert has_element?(view, "#library-selected li", "b.txt")
    end

    test "the cap is read again at submit: a limit lowered after the page loaded still holds", %{
      id: id
    } do
      library_config(max_files_per_add: 5)
      {view, _} = mount_view(id)

      upload_each(view, "#library-form", :library, [
        file("a.txt", "aaaaaa"),
        file("b.txt", "bbbbbb")
      ])

      # the page showed no alert and Add is enabled: the declared sizes were fine when it loaded
      refute render(view) =~ "add up to"
      refute has_element?(view, ~s(#library-form button[type="submit"][disabled]))

      Application.put_env(:foreman_server, :library, max_files_per_add: 5, upload_max_bytes: 10)

      assert submit(view, "kit") =~
               "These files add up to 12 B; at most 10 B can be added at once."

      assert list!(id) == []
      assert has_element?(view, "#library-selected li", "a.txt")
    end

    test "a total exactly at the cap is added", %{id: id} do
      library_config(max_files_per_add: 5, upload_max_bytes: 12)
      {view, _} = mount_view(id)

      upload_each(view, "#library-form", :library, [
        file("a.txt", "aaaaaa"),
        file("b.txt", "bbbbbb")
      ])

      refute render(view) =~ "add up to"
      assert submit(view, "kit") =~ "Added kit to the library (2 files)."
    end

    test "the folder form holds the same cap", %{id: id} do
      library_config(upload_max_bytes: 10)
      {view, _} = mount_view(id)

      upload_each(view, "#library-folder-form", :library_folder, [
        folder_file("kit", "a.md", "aaaaaa"),
        folder_file("kit", "b.md", "bbbbbb")
      ])

      assert has_element?(
               view,
               ~s(#library-folder-form [role="alert"]),
               "These files add up to 12 B; at most 10 B can be added at once."
             )

      assert has_element?(view, ~s(#library-folder-form button[type="submit"][disabled]))

      assert submit_folder(view, "") =~ "at most 10 B can be added at once."
      assert list!(id) == []
      assert has_element?(view, "#library-folder-selected li", "kit/a.md")
    end

    # LiveView's upload channel stops a client at the size it declared, so the bytes that
    # arrive can never exceed the declared sizes: the page's declared-size alert cannot be
    # dodged by declaring less (a lie is cut off, the entry disappears, nothing is added).
    # This is the third-party contract (deps/phoenix_live_view upload_channel.ex) the
    # declared-size check rests on.
    test "a client that sends more than it declared is cut off and adds nothing", %{id: id} do
      {view, _} = mount_view(id)

      upload =
        file_input(view, "#library-form", :library, [file("a.txt", String.duplicate("x", 40))])

      lying = %{upload | entries: Enum.map(upload.entries, &Map.put(&1, "size", 3))}
      render_upload(lying, "a.txt")

      Eventually.await(fn -> not has_element?(view, "#library-selected li") end)
      assert submit(view, "kit") =~ "Choose at least one file to add."
      assert list!(id) == []
    end
  end

  describe "replacing an entry's files" do
    test "a file entry keeps its id and name, loses its old files and takes the new ones", %{
      id: id,
      dir: dir
    } do
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)

      html = open_replace(view, old)
      assert html =~ "Replace kit"
      assert has_element?(view, "#library-entry-#{old.entry_id} #library-replace-form")
      assert has_element?(view, "#library-replace-form legend", "Replace kit")
      # a file entry takes files, not a folder
      refute has_element?(view, "#library-replace-form input[webkitdirectory]")

      upload_each(view, "#library-replace-form", :library_replace, [
        file("new1.txt", "fresh one"),
        file("new2.txt", "fresh two")
      ])

      html = submit_replace(view)
      assert html =~ "Replaced kit in the library (2 files)."

      # the same entry (id, name, kind), only its files changed
      assert [%{entry_id: id_after, name: "kit", kind: :file, file_count: 2} = entry] = list!(id)
      assert id_after == old.entry_id
      assert {:error, %{code: :not_found}} = Library.read(id, old.entry_id, "seed.txt")
      assert {:ok, "fresh one"} = Library.read(id, old.entry_id, "new1.txt")
      assert {:ok, "fresh two"} = Library.read(id, old.entry_id, "new2.txt")

      # the audit trail: a Replaced event after the Added one, and the index shows the new digest
      assert {:ok, events} = EventStore.read_stream_forward("project_library:#{id}", 0, 1000)

      assert Enum.map(events, & &1.event_type) ==
               ["ProjectLibraryAdded", "ProjectLibraryReplaced"]

      assert [
               %{
                 entry_id: ^id_after,
                 name: "kit",
                 kind: "file",
                 file_count: 2,
                 manifest_sha256: sha,
                 author_kind: "operator",
                 author_ref: "dashboard"
               }
             ] = ProjectionStore.project_library(id)

      assert sha == entry.manifest_sha256
      assert sha != old.manifest_sha256

      # the form closes and the list shows the new size, never any content
      refute has_element?(view, "#library-replace-form")
      assert has_element?(view, "#library-entry-#{old.entry_id}", "2 files")
      refute render(view) =~ "fresh one"
    end

    test "a folder entry is replaced with a folder: relative paths kept, the entry keeps its name",
         %{id: id, dir: dir} do
      old = seed_folder(id, dir, "docs", [{"old.md", "old"}, {"gone/x.md", "x"}])
      {view, _} = mount_view(id)

      open_replace(view, old)
      assert has_element?(view, "#library-replace-form input[type=file][webkitdirectory]")

      upload_each(view, "#library-replace-form", :library_replace, [
        folder_file("whatever", "new.md", "# New"),
        folder_file("whatever", "sub/n.txt", "nested"),
        folder_file("whatever", ".x", "hidden")
      ])

      html = submit_replace(view)
      assert html =~ "Replaced docs in the library (2 files; 1 skipped: hidden)."

      assert [%{entry_id: id_after, name: "docs", kind: :folder} = entry] = list!(id)
      assert id_after == old.entry_id
      assert entry.files |> Enum.map(& &1.path) |> Enum.sort() == ["new.md", "sub/n.txt"]
      assert {:ok, "# New"} = Library.read(id, old.entry_id, "new.md")
      assert {:ok, "nested"} = Library.read(id, old.entry_id, "sub/n.txt")
      assert {:error, %{code: :not_found}} = Library.read(id, old.entry_id, "old.md")
      assert {:error, %{code: :not_found}} = Library.read(id, old.entry_id, "gone/x.md")
      assert {:error, %{code: :not_found}} = Library.read(id, old.entry_id, ".x")

      assert [%{skipped_summary: %{"hidden" => 1}}] = ProjectionStore.project_library(id)
    end

    test "the form belongs to one entry at a time", %{id: id, dir: dir} do
      one = seed_entry(id, dir, "one", "1")
      two = seed_entry(id, dir, "two", "2")
      {view, _} = mount_view(id)

      open_replace(view, one)
      assert has_element?(view, "#library-entry-#{one.entry_id} #library-replace-form")

      open_replace(view, two)
      assert has_element?(view, "#library-entry-#{two.entry_id} #library-replace-form")
      refute has_element?(view, "#library-entry-#{one.entry_id} #library-replace-form")
      assert view |> element("#library-replace-form") |> render() =~ "Replace two"
    end

    test "an entry produced by a run is not offered a replacement, and a forged open is refused",
         %{id: id, dir: dir} do
      produced = seed_produced(id, dir, "run-1")
      keep = seed_entry(id, dir, "keep", "content")
      {view, _} = mount_view(id)

      assert has_element?(view, "#library-entry-#{produced.entry_id}", "produced-run-1")
      assert has_element?(view, "#library-entry-#{produced.entry_id} button", "Files of")
      refute has_element?(view, "#library-entry-#{produced.entry_id} button", "Replace")
      assert has_element?(view, "#library-entry-#{keep.entry_id} button", "Replace keep")

      html = render_click(view, "library_replace_open", %{"entry-id" => produced.entry_id})
      assert html =~ "Files produced by a run cannot be replaced here."
      refute has_element?(view, "#library-replace-form")
    end

    test "a forged or unknown entry id opens nothing and touches nothing", %{id: id, dir: dir} do
      keep = seed_entry(id, dir, "keep", "content")
      {view, _} = mount_view(id)

      for forged <- ["nope", "../../etc", "..", ""] do
        assert render_click(view, "library_replace_open", %{"entry-id" => forged}) =~
                 "That library entry no longer exists."

        refute has_element?(view, "#library-replace-form")
      end

      # a submit with no form open has nothing to replace
      assert render_submit(view, "library_replace", %{}) =~ "Choose an entry to replace first."

      assert [%{entry_id: id_after, manifest_sha256: sha}] = list!(id)
      assert id_after == keep.entry_id
      assert sha == keep.manifest_sha256
    end

    test "an entry removed while its form is open takes the form's state with it; a late replace is refused",
         %{id: id, dir: dir} do
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)
      upload_each(view, "#library-replace-form", :library_replace, [file("late.txt", "late")])
      assert has_element?(view, "#library-replace-selected li", "late.txt")

      # removed elsewhere (CLI, HTTP) after the form opened and a file was chosen
      assert {:ok, _} = Library.remove(id, old.entry_id, @operator)
      Eventually.await(fn -> not has_element?(view, "#library-entry-#{old.entry_id}") end)
      refute has_element?(view, "#library-replace-form")
      assert list!(id) == []

      # the refresh that dropped the row also closed the form and its selection: a submit
      # that still arrives has nothing to replace
      assert render_submit(view, "library_replace", %{}) =~ "Choose an entry to replace first."

      # the action itself refuses a stale id, whatever a form still says
      source = Path.join(dir, "late.txt")
      File.write!(source, "late")
      files = [%{relative_path: "late.txt", source_path: source}]

      assert {:error, "That library entry no longer exists."} =
               ForemanServerWeb.Workspace.Actions.library_replace(id, old.entry_id, files)

      assert list!(id) == []
    end

    test "the entry's stored kind decides how the files are read, never the caller", %{
      id: id,
      dir: dir
    } do
      file_entry = seed_entry(id, dir, "plain", "old")
      folder_entry = seed_folder(id, dir, "tree", [{"old.md", "old"}])

      sources =
        for rel <- ["new.md", ".dotfile"] do
          path = Path.join(dir, "src-#{rel}")
          File.write!(path, rel)
          %{relative_path: rel, source_path: path}
        end

      alias ForemanServerWeb.Workspace.Actions

      # a file entry keeps every file, a dotfile included
      assert {:ok, "Replaced plain in the library (2 files)."} =
               Actions.library_replace(id, file_entry.entry_id, sources)

      assert {:ok, ".dotfile"} = Library.read(id, file_entry.entry_id, ".dotfile")

      # a folder entry applies the folder rules to the very same files
      assert {:ok, "Replaced tree in the library (1 file; 1 skipped: hidden)."} =
               Actions.library_replace(id, folder_entry.entry_id, sources)

      assert {:error, %{code: :not_found}} = Library.read(id, folder_entry.entry_id, ".dotfile")
    end

    test "a file over the per-file limit is refused by the form and the entry is untouched", %{
      id: id,
      dir: dir
    } do
      library_config(max_file_bytes: 8)
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)

      input =
        file_input(view, "#library-replace-form", :library_replace, [
          file("big.bin", String.duplicate("x", 9))
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.bin")

      assert has_element?(
               view,
               "#library-replace-selected li",
               "This file is over the per-file limit."
             )

      assert submit_replace(view) =~ "cancel and choose again"
      assert {:ok, "old"} = Library.read(id, old.entry_id, "seed.txt")
    end

    test "the whole-add cap holds for a replacement: alert, disabled button, refused submit", %{
      id: id,
      dir: dir
    } do
      library_config(max_files_per_add: 5, upload_max_bytes: 10)
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)

      upload_each(view, "#library-replace-form", :library_replace, [
        file("a.txt", "aaaaaa"),
        file("b.txt", "bbbbbb")
      ])

      assert has_element?(
               view,
               ~s(#library-replace-form [role="alert"]),
               "These files add up to 12 B; at most 10 B can be added at once."
             )

      assert has_element?(view, ~s(#library-replace-form button[type="submit"][disabled]))

      assert submit_replace(view) =~ "at most 10 B can be added at once."
      assert {:ok, "old"} = Library.read(id, old.entry_id, "seed.txt")
      assert has_element?(view, "#library-replace-selected li", "a.txt")
    end

    test "too many files are refused by the form", %{id: id, dir: dir} do
      library_config(max_files_per_add: 2, folder_max_files: 2)
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)

      files = [file("a.txt", "a"), file("b.txt", "b"), file("c.txt", "c")]
      input = file_input(view, "#library-replace-form", :library_replace, files)
      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "a.txt")

      assert render(view) =~ "Too many files: choose at most 2."
      assert submit_replace(view) =~ "cancel and choose again"
      assert {:ok, "old"} = Library.read(id, old.entry_id, "seed.txt")
    end

    test "Cancel closes the form and drops the pending selection", %{id: id, dir: dir} do
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)
      upload_each(view, "#library-replace-form", :library_replace, [file("new.txt", "fresh")])
      assert has_element?(view, "#library-replace-selected li", "new.txt")

      view
      |> element("#library-replace-form button", "Cancel replacing kit")
      |> render_click()

      refute has_element?(view, "#library-replace-form")

      # opened again, the form starts empty
      open_replace(view, old)
      Eventually.await(fn -> not has_element?(view, "#library-replace-selected") end)
      assert has_element?(view, "#library-replace-form")

      assert {:ok, "old"} = Library.read(id, old.entry_id, "seed.txt")
      assert {:error, %{code: :not_found}} = Library.read(id, old.entry_id, "new.txt")
    end

    test "a refused replace (a hostile name) keeps the selection and the entry", %{
      id: id,
      dir: dir
    } do
      old = seed_entry(id, dir, "kit", "old")
      {view, _} = mount_view(id)
      open_replace(view, old)
      upload_each(view, "#library-replace-form", :library_replace, [file("../evil.txt", "owned")])

      html = submit_replace(view)
      assert html =~ "Could not replace:"
      assert html =~ "invalid library path"
      assert has_element?(view, "#library-replace-form")
      assert has_element?(view, "#library-replace-selected li", "../evil.txt")
      refute File.exists?(Path.join(dir, "evil.txt"))
      assert {:ok, "old"} = Library.read(id, old.entry_id, "seed.txt")
      assert [%{manifest_sha256: sha}] = list!(id)
      assert sha == old.manifest_sha256
    end

    test "submitting with nothing chosen is refused", %{id: id, dir: dir} do
      file_entry = seed_entry(id, dir, "kit", "old")
      folder_entry = seed_folder(id, dir, "tree", [{"a.md", "a"}])
      {view, _} = mount_view(id)

      open_replace(view, file_entry)
      assert submit_replace(view) =~ "Choose the files that replace it."

      open_replace(view, folder_entry)
      assert submit_replace(view) =~ "Choose the folder that replaces it."

      assert {:ok, "old"} = Library.read(id, file_entry.entry_id, "seed.txt")
    end

    test "an archived project refuses the replacement with the library's reason", %{
      id: id,
      dir: dir
    } do
      old = seed_entry(id, dir, "kit", "old")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "archive-#{id}",
                 type: "project.archive",
                 aggregate_id: "project:#{id}",
                 payload: %{project_id: id}
               })

      {view, _} = mount_view(id)
      open_replace(view, old)
      upload_each(view, "#library-replace-form", :library_replace, [file("new.txt", "n")])

      assert submit_replace(view) =~ "Could not replace: project is archived"
    end
  end

  describe "downloading files" do
    test "the toggle lists an entry's files with their sizes and a button for each", %{
      id: id,
      dir: dir
    } do
      entry = seed_files(id, dir, "kit", [{"docs/guide.md", "# Guide"}, {"data.csv", "a,b"}])
      {view, _} = mount_view(id)

      refute has_element?(view, "#library-files-#{entry.entry_id}")

      assert has_element?(
               view,
               ~s(#library-entry-#{entry.entry_id} button[aria-expanded="false"]),
               "Files of kit"
             )

      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()

      assert has_element?(
               view,
               ~s(#library-entry-#{entry.entry_id} button[aria-expanded="true"]),
               "Files of kit"
             )

      assert has_element?(view, "#library-files-#{entry.entry_id} li", "docs/guide.md")
      assert has_element?(view, "#library-files-#{entry.entry_id} li", "(7 B)")
      assert has_element?(view, "#library-files-#{entry.entry_id} li", "data.csv")

      assert has_element?(
               view,
               "#library-files-#{entry.entry_id} button",
               "Download docs/guide.md"
             )

      assert has_element?(view, "#library-files-#{entry.entry_id} button", "Download data.csv")

      # the same button closes it
      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()
      refute has_element?(view, "#library-files-#{entry.entry_id}")
    end

    test "Download pushes the exact bytes to the browser, never into the page", %{
      id: id,
      dir: dir
    } do
      binary = <<0, 255, 128, 10, 13, 0>>
      entry = seed_files(id, dir, "kit", [{"docs/guide.md", "# Guide"}, {"bin/data.bin", binary}])
      {view, _} = mount_view(id)
      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()

      html =
        view
        |> element("#library-files-#{entry.entry_id} button", "Download docs/guide.md")
        |> render_click()

      assert_push_event(view, "library-download", %{name: "guide.md", data: data}, 1_000)
      assert Base.decode64!(data) == "# Guide"
      assert html =~ "Downloading guide.md."

      view
      |> element("#library-files-#{entry.entry_id} button", "Download bin/data.bin")
      |> render_click()

      assert_push_event(view, "library-download", %{name: "data.bin", data: data}, 1_000)
      assert Base.decode64!(data) == binary

      # file content stays out of the rendered page
      refute render(view) =~ "# Guide"
      refute render(view) =~ Base.encode64("# Guide")
    end

    test "a file over the read limit is listed without a button and cannot be forced", %{
      id: id,
      dir: dir
    } do
      big = String.duplicate("x", Library.read_max_bytes() + 1)
      entry = seed_files(id, dir, "kit", [{"big.bin", big}, {"small.txt", "s"}])
      {view, _} = mount_view(id)
      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()

      assert has_element?(view, "#library-files-#{entry.entry_id} li", "big.bin")

      assert has_element?(
               view,
               "#library-files-#{entry.entry_id} li",
               "over the 1 MiB read limit"
             )

      refute has_element?(view, "#library-files-#{entry.entry_id} button", "Download big.bin")
      assert has_element?(view, "#library-files-#{entry.entry_id} button", "Download small.txt")

      html =
        render_click(view, "library_download", %{
          "entry-id" => entry.entry_id,
          "path" => "big.bin"
        })

      assert html =~ "Could not download:"
      assert html =~ "read at most #{Library.read_max_bytes()}"
      refute_push_event(view, "library-download", %{})
    end

    test "a forged entry id or path is an error notice, not a download and not a crash", %{
      id: id,
      dir: dir
    } do
      entry = seed_files(id, dir, "kit", [{"docs/guide.md", "# Guide"}])
      {view, _} = mount_view(id)

      forged = [
        {"nope", "docs/guide.md"},
        {"../../etc", "docs/guide.md"},
        {"", "docs/guide.md"},
        {entry.entry_id, "../../../../etc/passwd"},
        {entry.entry_id, "/etc/passwd"},
        {entry.entry_id, "docs//guide.md"},
        {entry.entry_id, "docs/../docs/guide.md"},
        {entry.entry_id, "docs"},
        {entry.entry_id, "missing.md"},
        {entry.entry_id, ""}
      ]

      for {entry_id, path} <- forged do
        html = render_click(view, "library_download", %{"entry-id" => entry_id, "path" => path})

        assert html =~ "Could not download:" or html =~ "That file is no longer in the library.",
               "expected a refusal for #{inspect({entry_id, path})}"
      end

      refute_push_event(view, "library-download", %{})
      assert Process.alive?(view.pid)
    end

    test "the list follows its entry: a replacement shows the new files, a removal closes it", %{
      id: id,
      dir: dir
    } do
      entry = seed_files(id, dir, "kit", [{"old.txt", "old"}])
      {view, _} = mount_view(id)
      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()
      assert has_element?(view, "#library-files-#{entry.entry_id} li", "old.txt")

      # replaced elsewhere (CLI, HTTP)
      source = Path.join(dir, "new-source.txt")
      File.write!(source, "new")

      assert {:ok, _} =
               Library.replace(
                 id,
                 entry.entry_id,
                 {:files, [%{relative_path: "new.txt", source_path: source}]},
                 %{},
                 @operator
               )

      Eventually.await(fn ->
        has_element?(view, "#library-files-#{entry.entry_id} li", "new.txt") and
          not has_element?(view, "#library-files-#{entry.entry_id} li", "old.txt")
      end)

      assert {:ok, _} = Library.remove(id, entry.entry_id, @operator)
      Eventually.await(fn -> not has_element?(view, "#library-files-#{entry.entry_id}") end)
      refute has_element?(view, "#library-entry-#{entry.entry_id}")
    end

    test "removing the entry through the page closes its open file list", %{id: id, dir: dir} do
      entry = seed_files(id, dir, "kit", [{"a.txt", "a"}])
      {view, _} = mount_view(id)
      view |> element("#library-entry-#{entry.entry_id} button", "Files of kit") |> render_click()

      view |> element("#library-list button", "Remove kit") |> render_click()
      view |> element("#library-list button", "Confirm remove kit") |> render_click()

      refute has_element?(view, "#library-files-#{entry.entry_id}")
      assert list!(id) == []
    end

    test "the root layout carries the listener that saves the pushed bytes", %{id: id} do
      html =
        build_conn()
        |> get("/dashboard/projects/#{id}?token=#{@token}")
        |> html_response(200)

      assert html =~ "window.addEventListener(\"phx:library-download\""
      assert html =~ "event.detail.data"
      assert html =~ "link.download = event.detail.name"
      assert html =~ "application/octet-stream"
      # the LiveSocket bootstrap it sits next to is still there
      assert html =~ "liveSocket.connect()"
    end
  end

  defp list!(id) do
    assert {:ok, entries} = Library.list(id)
    entries
  end
end
