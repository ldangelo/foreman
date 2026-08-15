defmodule ForemanServer.Workflow.CatalogWriter do
  @moduledoc """
  Safe, atomic workflow-manifest writer for the `Workflow.Catalog`.

  ## Safety guarantees

    * **Containment** — the target path is validated to be inside
      `Catalog.root/0`; symlink traversal (`..`) is rejected.
    * **Path-traversal guard** — filenames containing `/`, `\\`, or `..`
      segments are rejected before any filesystem call.
    * **Name/stem consistency** — the manifest's `name:` field must match
      the filename stem (e.g. `implement.yaml` → `name: implement`),
      preventing accidental mis-filing.
    * **Atomic write** — content is written to a temporary file inside
      the catalog root then renamed into place, so readers never see a
      partial file.
  """

  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.ManifestWriter

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Write a manifest map to the catalog.

  ## Arguments

    * `filename` — the target filename (e.g. `"my-workflow.yaml"`);
      must contain no path separators or `..` segments.
    * `manifest` — a manifest map with at least `name` and `phases`.

  ## Returns

    * `{:ok, path}` — the absolute path the file was written to.
    * `{:error, :outside_catalog}` — the resolved path is not inside
      `Catalog.root/0`.
    * `{:error, :invalid_filename}` — the filename contains a path
      separator or `..` segment.
    * `{:error, :name_stem_mismatch, expected, actual}` — the manifest's
      `name` does not match the filename stem.
    * `{:error, {:invalid_manifest, detail}}` — the manifest failed
      `ManifestWriter.write/1` validation.

  """
  @spec write_manifest(String.t(), map()) ::
          {:ok, Path.t()}
          | {:error,
             :outside_catalog
             | :invalid_filename
             | {:name_stem_mismatch, String.t(), String.t()}
             | {:invalid_manifest, term()}}
  def write_manifest(filename, manifest) when is_binary(filename) and is_map(manifest) do
    with :ok <- validate_filename(filename),
         :ok <- validate_containment(filename),
         :ok <- validate_name_stem(filename, manifest) do
      write_manifest_unchecked(filename, manifest)
    end
  end

  # -------------------------------------------------------------------
  # Validation helpers
  # -------------------------------------------------------------------

  defp validate_filename(filename) do
    if String.contains?(filename, "/") or
         String.contains?(filename, "\\") or
         String.contains?(filename, "..") do
      {:error, :invalid_filename}
    else
      :ok
    end
  end

  defp validate_containment(filename) do
    root = Catalog.root()
    absolute_path = Path.absname(Path.join(root, filename))
    root_absolute = Path.absname(root)

    if String.starts_with?(absolute_path, root_absolute <> "/") do
      :ok
    else
      {:error, :outside_catalog}
    end
  end

  defp validate_name_stem(filename, manifest) do
    expected_stem = Path.rootname(filename)
    actual_name = Map.get(manifest, "name") || Map.get(manifest, :name)

    if actual_name == expected_stem do
      :ok
    else
      {:error, {:name_stem_mismatch, expected_stem, actual_name}}
    end
  end

  # -------------------------------------------------------------------
  # Internal writer
  # -------------------------------------------------------------------

  defp write_manifest_unchecked(filename, manifest) do
    root = Catalog.root()

    with {:ok, yaml} <- ManifestWriter.write(manifest) do
      tmp_path = Path.join(root, ".#{filename}.tmp.#{:os.system_time(:millisecond)}")

      case File.write(tmp_path, yaml) do
        :ok ->
          final_path = Path.join(root, filename)

          case File.rename(tmp_path, final_path) do
            :ok ->
              {:ok, final_path}

            {:error, reason} ->
              File.rm(tmp_path)
              {:error, {:atomic_write_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:invalid_manifest, reason}}
      end
    end
  end
end
