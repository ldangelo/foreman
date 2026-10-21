defmodule ForemanServer.Library.Entry do
  @moduledoc """
  One library entry as it exists on disk (`<entry_id>/entry.json`).

  `manifest_sha256` is the digest over the sorted `path NUL sha256 NUL bytes`
  lines of `files`, so two entries with the same files have the same digest.
  `source` is `%{"kind" => "upload" | "server_path" | "thread", ...}` metadata;
  `skipped` is the list of `%{"path", "reason"}` left out at ingest.
  """

  @type file :: %{path: String.t(), bytes: non_neg_integer(), sha256: String.t()}
  @type t :: %__MODULE__{
          entry_id: String.t(),
          name: String.t(),
          kind: :file | :folder | :produced,
          source: map(),
          files: [file()],
          skipped: [%{path: String.t(), reason: String.t()}],
          file_count: non_neg_integer(),
          bytes: non_neg_integer(),
          manifest_sha256: String.t(),
          created_at: String.t(),
          replaced_at: String.t() | nil
        }
  @enforce_keys [:entry_id, :name, :kind, :files, :manifest_sha256, :created_at]
  defstruct [
    :entry_id,
    :name,
    :kind,
    :manifest_sha256,
    :created_at,
    :replaced_at,
    source: %{},
    files: [],
    skipped: [],
    file_count: 0,
    bytes: 0
  ]

  @doc "Digest over the sorted file list."
  @spec manifest_sha256([file()]) :: String.t()
  def manifest_sha256(files) do
    files
    |> Enum.sort_by(& &1.path)
    |> Enum.map_join("\n", fn f ->
      f.path <> <<0>> <> f.sha256 <> <<0>> <> Integer.to_string(f.bytes)
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Serialisable map for `entry.json`."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = e) do
    %{
      "schema" => "foreman.library.entry.v1",
      "entry_id" => e.entry_id,
      "name" => e.name,
      "kind" => Atom.to_string(e.kind),
      "source" => e.source,
      "files" =>
        Enum.map(e.files, &%{"path" => &1.path, "bytes" => &1.bytes, "sha256" => &1.sha256}),
      "skipped" => Enum.map(e.skipped, &%{"path" => &1.path, "reason" => &1.reason}),
      "file_count" => e.file_count,
      "bytes" => e.bytes,
      "manifest_sha256" => e.manifest_sha256,
      "created_at" => e.created_at,
      "replaced_at" => e.replaced_at
    }
  end

  @doc "Parses an `entry.json` map; `:error` when it is not a v1 entry."
  @spec from_json_map(term()) :: {:ok, t()} | :error
  def from_json_map(
        %{
          "schema" => "foreman.library.entry.v1",
          "entry_id" => id,
          "name" => name,
          "kind" => kind,
          "files" => files,
          "manifest_sha256" => sha,
          "created_at" => created
        } = map
      )
      when is_binary(id) and is_binary(name) and kind in ["file", "folder", "produced"] and
             is_list(files) and is_binary(sha) and is_binary(created) do
    parsed =
      Enum.map(files, fn
        %{"path" => p, "bytes" => b, "sha256" => s}
        when is_binary(p) and is_integer(b) and is_binary(s) ->
          %{path: p, bytes: b, sha256: s}

        _ ->
          :bad
      end)

    if :bad in parsed do
      :error
    else
      skipped =
        for %{"path" => p, "reason" => r} <- Map.get(map, "skipped", []) || [],
            do: %{path: p, reason: r}

      {:ok,
       %__MODULE__{
         entry_id: id,
         name: name,
         kind: kind_atom(kind),
         source: Map.get(map, "source") || %{},
         files: parsed,
         skipped: skipped,
         file_count: length(parsed),
         bytes: Enum.reduce(parsed, 0, &(&1.bytes + &2)),
         manifest_sha256: sha,
         created_at: created,
         replaced_at: Map.get(map, "replaced_at")
       }}
    end
  end

  def from_json_map(_), do: :error

  defp kind_atom("file"), do: :file
  defp kind_atom("folder"), do: :folder
  defp kind_atom("produced"), do: :produced
end
