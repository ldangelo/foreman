defmodule ForemanServerWeb.Workspace.LibraryUpload do
  @moduledoc """
  The rules of a library upload from the browser, shared by the workspace's three
  socket upload forms (add files, add a folder, replace an entry's files).

  `upload_opts/2` gives the `allow_upload/3` options. The count and per-file limits
  are the library's (`Library.Ingest.limits/0`), the per-file limit clamped to
  `upload_max_bytes` so that no single file can outgrow the cap.

  `upload_max_bytes` caps the total size of ONE add. Over HTTP
  `ForemanServerWeb.Plugs.LibraryUploadParser` enforces it on the request body.
  LiveView has no cumulative cap (`allow_upload/3` bounds each file and the number
  of files, never their sum), so the workspace enforces it explicitly, in two steps:

    * `declared_bytes/1` sums the sizes the browser announced for the valid entries.
      The forms show an alert and disable their submit button when the sum is over
      the cap, so an honest browser never starts the transfer (without
      `auto_upload`, LiveView transfers the files when the form is submitted).
    * `actual_bytes/1` sums the sizes of the files that really arrived. The submit
      handlers refuse an over-cap selection with it before anything reaches
      `Library`. LiveView cuts a client off at the size it declared, so this sum
      cannot exceed the declared one; it is the check that depends neither on what
      the browser claimed nor on the limits the page was rendered with.

  `flat_files/1` and `folder_files/1` turn a selection into the files `Library`
  takes. A relative path is the browser's `webkitRelativePath`, so it is untrusted:
  `Library.Ingest` validates every path again.
  """

  alias ForemanServer.Library.Ingest
  alias Phoenix.LiveView.{UploadConfig, UploadEntry}

  @typedoc """
  `:files` for a pick of single files, `:folder` for a pick of a directory, `:replace`
  for the files that replace an entry (a file entry takes files, a folder entry a folder).
  """
  @type form :: :files | :folder | :replace

  @typedoc "An uploaded entry with the temp path LiveView holds its bytes at."
  @type selected :: {UploadEntry.t(), Path.t()}

  @doc """
  `allow_upload/3` options of a form: at most `max_files_per_add` entries for a pick
  of files, `folder_max_files` for a folder, the larger of the two for a replacement
  (it serves both kinds of entry), each file at most `max_file_size/1`.
  """
  @spec upload_opts(form(), map()) :: keyword()
  def upload_opts(form, limits),
    do: [
      accept: :any,
      max_entries: max_entries(form, limits),
      max_file_size: max_file_size(limits)
    ]

  defp max_entries(:files, limits), do: limits.max_files_per_add
  defp max_entries(:folder, limits), do: limits.folder_max_files
  defp max_entries(:replace, limits), do: max(limits.max_files_per_add, limits.folder_max_files)

  @doc "The per-file limit: the library's, and never more than the whole add may hold."
  @spec max_file_size(map()) :: pos_integer()
  def max_file_size(limits), do: min(limits.max_file_bytes, limits.upload_max_bytes)

  @doc "The summed sizes the browser announced for the valid, not cancelled entries."
  @spec declared_bytes(UploadConfig.t()) :: non_neg_integer()
  def declared_bytes(%UploadConfig{entries: entries}) do
    sizes =
      for %UploadEntry{valid?: true, cancelled?: false, client_size: size} <- entries, do: size

    Enum.sum(sizes)
  end

  @doc "The announced total when it is over `max`, else `nil`."
  @spec declared_over_cap(UploadConfig.t(), pos_integer()) :: non_neg_integer() | nil
  def declared_over_cap(%UploadConfig{} = upload, max) do
    case declared_bytes(upload) do
      total when total > max -> total
      _within -> nil
    end
  end

  @doc "The summed sizes on disk of the uploaded temp files (`File.stat!/1`: a missing one raises)."
  @spec actual_bytes([selected()]) :: non_neg_integer()
  def actual_bytes(selected),
    do: selected |> Enum.map(fn {_entry, path} -> File.stat!(path).size end) |> Enum.sum()

  @doc "A pick of single files: each file is a top-level file of the entry, named as uploaded."
  @spec flat_files([selected()]) :: [Ingest.file_source()]
  def flat_files(selected),
    do: for({%UploadEntry{client_name: name}, path} <- selected, do: source(name, path))

  @doc """
  A picked folder: `{name, files}`. The browser sends every file as
  `<folder>/<path inside it>`. When all of them share that first segment it is the
  folder's own name: it is dropped from the paths and, when `Ingest.valid_name?/1`
  accepts it, returned as the suggested entry name (else `nil`, and the library
  derives one). A file without a relative path keeps its plain name.
  """
  @spec folder_files([selected()]) :: {String.t() | nil, [Ingest.file_source()]}
  def folder_files(selected) do
    files = for {entry, path} <- selected, do: source(relative_path(entry), path)

    case common_root(files) do
      {:ok, root} ->
        name = if Ingest.valid_name?(root), do: root
        {name, Enum.map(files, &strip_root(&1, root))}

      :none ->
        {nil, files}
    end
  end

  defp source(relative_path, path), do: %{relative_path: relative_path, source_path: path}

  # `webkitRelativePath` is "" for a file that was not picked as part of a directory.
  defp relative_path(%UploadEntry{client_relative_path: rel, client_name: name})
       when rel in [nil, ""],
       do: name

  defp relative_path(%UploadEntry{client_relative_path: rel}), do: rel

  # The first segment every path shares, when each path sits below it. `.`, `..` and
  # an empty segment are never a folder name: the paths stay as they are and the
  # library refuses them.
  defp common_root(files) do
    roots =
      for %{relative_path: rel} <- files do
        case String.split(rel, "/", parts: 2) do
          [root, _inside] -> root
          [_single] -> nil
        end
      end

    case Enum.uniq(roots) do
      [root] when is_binary(root) and root not in ["", ".", ".."] -> {:ok, root}
      _ -> :none
    end
  end

  defp strip_root(%{relative_path: rel} = file, root),
    do: %{file | relative_path: String.replace_prefix(rel, root <> "/", "")}
end
