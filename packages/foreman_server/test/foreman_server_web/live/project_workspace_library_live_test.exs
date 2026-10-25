defmodule ForemanServerWeb.ProjectWorkspaceLibraryLiveTest do
  # foreman-8ervf: the workspace's Library tab adds and removes library files. The
  # upload goes through `Library.add/4`, the call behind the HTTP route and the CLI,
  # so its name, path, count and size rules are the library's, not the browser's.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, Library, ProjectionStore, ProjectStore}
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

  defp list!(id) do
    assert {:ok, entries} = Library.list(id)
    entries
  end
end
