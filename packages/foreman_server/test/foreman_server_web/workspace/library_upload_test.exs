defmodule ForemanServerWeb.Workspace.LibraryUploadTest do
  # foreman-8ervf: the rules the workspace's three upload forms share, on several files at
  # once. (LiveViewTest's upload client cannot drive every multi-file case through a view.)
  use ExUnit.Case, async: true

  alias ForemanServer.Library.Ingest
  alias ForemanServerWeb.Workspace.LibraryUpload
  alias Phoenix.LiveView.{UploadConfig, UploadEntry}

  @moduletag :tmp_dir

  defp entry(name, opts) do
    struct!(UploadEntry, [client_name: name, valid?: true, client_size: 1] ++ opts)
  end

  defp config(entries), do: %UploadConfig{entries: entries}

  # An uploaded entry with its temp file on disk, the shape `consume_uploaded_entries/3`
  # hands the submit handlers (`{:postpone, {entry, path}}`).
  defp selected(dir, name, content, opts \\ []) do
    path = Path.join(dir, "tmp-#{System.unique_integer([:positive])}-#{Path.basename(name)}")
    File.write!(path, content)
    {entry(name, opts), path}
  end

  defp limits(overrides \\ %{}),
    do:
      Ingest.limits(
        Map.merge(
          %{max_files_per_add: 4, folder_max_files: 9, max_file_bytes: 100, upload_max_bytes: 50},
          overrides
        )
      )

  describe "upload_opts/2 and max_file_size/1" do
    test "each form takes the count of its kind; a replacement takes the larger" do
      assert [accept: :any, max_entries: 4, max_file_size: 50] =
               LibraryUpload.upload_opts(:files, limits())

      assert [accept: :any, max_entries: 9, max_file_size: 50] =
               LibraryUpload.upload_opts(:folder, limits())

      assert [accept: :any, max_entries: 9, max_file_size: 50] =
               LibraryUpload.upload_opts(:replace, limits())

      # the larger of the two counts, whichever kind of entry it is
      assert [max_entries: 12, max_file_size: 50] =
               Keyword.take(
                 LibraryUpload.upload_opts(:replace, limits(%{max_files_per_add: 12})),
                 [:max_entries, :max_file_size]
               )
    end

    test "a file may not outgrow the whole add: the per-file limit is clamped to the cap" do
      assert LibraryUpload.max_file_size(limits(%{max_file_bytes: 100, upload_max_bytes: 50})) ==
               50

      assert LibraryUpload.max_file_size(limits(%{max_file_bytes: 20, upload_max_bytes: 50})) ==
               20

      assert LibraryUpload.max_file_size(limits(%{max_file_bytes: 50, upload_max_bytes: 50})) ==
               50
    end
  end

  describe "declared_bytes/1 and declared_over_cap/2" do
    test "sum the sizes of the valid entries that are not cancelled" do
      upload =
        config([
          entry("a", client_size: 6),
          entry("b", client_size: 4),
          entry("too-big", client_size: 1_000, valid?: false),
          entry("gone", client_size: 100, cancelled?: true)
        ])

      assert LibraryUpload.declared_bytes(upload) == 10
    end

    test "a total exactly at the cap is within it; one byte more is over" do
      at_cap = config([entry("a", client_size: 6), entry("b", client_size: 4)])
      over_cap = config([entry("a", client_size: 6), entry("b", client_size: 5)])

      assert LibraryUpload.declared_over_cap(at_cap, 10) == nil
      assert LibraryUpload.declared_over_cap(over_cap, 10) == 11
      assert LibraryUpload.declared_over_cap(config([]), 10) == nil
    end
  end

  describe "actual_bytes/1" do
    test "sums what is on disk, whatever the entries claim", %{tmp_dir: dir} do
      # both entries claim 1 byte; the files are 5 and 7
      files = [selected(dir, "a.txt", "aaaaa"), selected(dir, "b.txt", "bbbbbbb")]

      assert LibraryUpload.actual_bytes(files) == 12
      assert LibraryUpload.actual_bytes([]) == 0
    end

    test "a temp file that is gone raises instead of counting as zero", %{tmp_dir: dir} do
      {_entry, path} = file = selected(dir, "a.txt", "aaaaa")
      File.rm!(path)

      assert_raise File.Error, fn -> LibraryUpload.actual_bytes([file]) end
    end
  end

  describe "flat_files/1" do
    test "every file is a top-level file named as uploaded, even one that carries a path",
         %{tmp_dir: dir} do
      {_, p1} = a = selected(dir, "guide.md", "x")
      {_, p2} = b = selected(dir, "data.csv", "y", client_relative_path: "ignored/data.csv")

      assert LibraryUpload.flat_files([a, b]) == [
               %{relative_path: "guide.md", source_path: p1},
               %{relative_path: "data.csv", source_path: p2}
             ]
    end

    test "a hostile name is passed through for the library to refuse", %{tmp_dir: dir} do
      {_, path} = file = selected(dir, "../evil.txt", "x")

      assert [%{relative_path: "../evil.txt", source_path: ^path}] =
               LibraryUpload.flat_files([file])
    end
  end

  describe "folder_files/1" do
    test "drops the folder's own name, keeps the paths below it and suggests it as the name",
         %{tmp_dir: dir} do
      {_, p1} = a = selected(dir, "a.md", "x", client_relative_path: "kit/docs/a.md")
      {_, p2} = b = selected(dir, "b.txt", "y", client_relative_path: "kit/b.txt")
      {_, p3} = c = selected(dir, "n.txt", "z", client_relative_path: "kit/docs/deep/n.txt")

      assert {"kit",
              [
                %{relative_path: "docs/a.md", source_path: ^p1},
                %{relative_path: "b.txt", source_path: ^p2},
                %{relative_path: "docs/deep/n.txt", source_path: ^p3}
              ]} = LibraryUpload.folder_files([a, b, c])
    end

    test "a folder name that is not a valid entry name is dropped from the paths but not suggested",
         %{tmp_dir: dir} do
      a = selected(dir, "a.md", "x", client_relative_path: "my.docs/a.md")
      b = selected(dir, "b.md", "x", client_relative_path: "my.docs/sub/b.md")

      assert {nil, [%{relative_path: "a.md"}, %{relative_path: "sub/b.md"}]} =
               LibraryUpload.folder_files([a, b])
    end

    test "files that do not share a first segment keep their paths and suggest nothing",
         %{tmp_dir: dir} do
      a = selected(dir, "a.md", "x", client_relative_path: "one/a.md")
      b = selected(dir, "b.md", "x", client_relative_path: "two/b.md")

      assert {nil, [%{relative_path: "one/a.md"}, %{relative_path: "two/b.md"}]} =
               LibraryUpload.folder_files([a, b])
    end

    test "a file without a relative path keeps its plain name and nothing is dropped",
         %{tmp_dir: dir} do
      for none <- [nil, ""] do
        a = selected(dir, "a.md", "x", client_relative_path: "kit/a.md")
        b = selected(dir, "loose.txt", "y", client_relative_path: none)

        assert {nil, [%{relative_path: "kit/a.md"}, %{relative_path: "loose.txt"}]} =
                 LibraryUpload.folder_files([a, b])
      end
    end

    test "a single file picked as a folder still loses the folder name", %{tmp_dir: dir} do
      a = selected(dir, "a.md", "x", client_relative_path: "kit/a.md")

      assert {"kit", [%{relative_path: "a.md"}]} = LibraryUpload.folder_files([a])
    end

    test "`.`, `..` and an empty first segment are never a folder name: the library refuses them",
         %{tmp_dir: dir} do
      for root <- ["..", ".", ""] do
        a = selected(dir, "x.txt", "x", client_relative_path: "#{root}/x.txt")

        assert {nil, [%{relative_path: path}]} = LibraryUpload.folder_files([a])
        assert path == "#{root}/x.txt"
        assert {:error, %{code: :path_invalid}} = Ingest.validate_relative_path(path)
      end
    end

    test "nothing selected is nothing to name" do
      assert {nil, []} = LibraryUpload.folder_files([])
    end
  end
end
