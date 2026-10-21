defmodule ForemanServer.Library.Produced do
  @moduledoc """
  Rules for thread-produced files (E5-S5): files an agent run leaves behind (phase
  artifacts, the session archive's `analysis.md` / `diff.patch`) registered into
  the project library under ONE entry per run.

    * entry name `produced-<run_id>` (sanitised) and a deterministic entry id, so
      registration is idempotent per run;
    * kind `:produced`: exempt from the 10-folder cap;
    * idempotent per `(run_id, relative_path, sha256)`: re-registering identical
      content changes nothing, new content at the same path replaces that file;
    * bounded per run by `config :foreman_server, :library, produced_max_files_per_run`
      and `produced_max_bytes_per_run`; the budget counts files already registered;
    * containment: a source file is accepted only when it is a regular file, not a
      symlink, and its path (with no symlinked directory on the way) lies under one of
      the caller's allowed roots. Nothing outside those roots is ever read.

  Secrets in copied text files are NOT redacted: the files are agent output, with
  the same exposure as the git branch the run pushes. Callers that know a file was
  already redacted (the archive marks them) skip the ones they should not copy.
  """

  alias ForemanServer.Library.{Entry, Error, Ingest, Plan}
  alias ForemanServer.Library.Plan.Item

  @chunk 65_536

  @type file_source :: Ingest.file_source()

  @doc "The produced entry's name for a run."
  @spec entry_name(String.t()) :: String.t()
  def entry_name(run_id) do
    cleaned =
      run_id
      |> String.replace(~r/[^A-Za-z0-9_ -]+/, "-")
      |> String.replace(~r/\A[^A-Za-z0-9]+/, "")

    ("produced-" <> cleaned) |> String.slice(0, 128)
  end

  @doc "The deterministic entry id for a run."
  @spec entry_id(String.t()) :: String.t()
  def entry_id(run_id) do
    slug =
      run_id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    suffix =
      :sha256 |> :crypto.hash(run_id) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    "produced-" <> if(slug == "", do: suffix, else: slug <> "-" <> suffix)
  end

  @doc """
  Plans the entry after adding `files` to `existing` (`nil` for the first
  registration). `files_dir` is where `existing`'s files live. Returns `:unchanged`
  when nothing differs, `{:ok, plan}` otherwise, or a typed error.
  """
  @spec plan(String.t(), Entry.t() | nil, String.t() | nil, [file_source()], [String.t()]) ::
          :unchanged | {:ok, Plan.t()} | {:error, Error.t()}
  def plan(run_id, existing, files_dir, files, allowed_roots) do
    with {:ok, incoming} <- incoming(files, allowed_roots) do
      known = if existing, do: Map.new(existing.files, &{&1.path, &1.sha256}), else: %{}

      changed =
        Enum.reject(incoming, fn {item, sha} -> Map.get(known, item.relative_path) == sha end)

      if changed == [] do
        :unchanged
      else
        build(run_id, existing, files_dir, Enum.map(changed, &elem(&1, 0)))
      end
    end
  end

  defp build(run_id, existing, files_dir, changed) do
    replaced = MapSet.new(changed, & &1.relative_path)

    kept =
      for f <- (existing && existing.files) || [], not MapSet.member?(replaced, f.path) do
        %Item{relative_path: f.path, source_path: Path.join(files_dir, f.path), bytes: f.bytes}
      end

    items = Enum.sort_by(kept ++ changed, & &1.relative_path)
    bytes = Enum.reduce(items, 0, &(&1.bytes + &2))
    {max_files, max_bytes} = limits()

    if length(items) > max_files or bytes > max_bytes do
      {:error,
       Error.new(
         :produced_over_budget,
         "run #{run_id} would exceed its produced-file budget " <>
           "(#{length(items)}/#{max_files} files, #{bytes}/#{max_bytes} bytes)",
         %{files: length(items), bytes: bytes, max_files: max_files, max_bytes: max_bytes}
       )}
    else
      {:ok, %Plan{kind: :produced, name: entry_name(run_id), files: items, total_bytes: bytes}}
    end
  end

  defp limits do
    config = Application.get_env(:foreman_server, :library, [])

    {Keyword.get(config, :produced_max_files_per_run, 100),
     Keyword.get(config, :produced_max_bytes_per_run, 50 * 1024 * 1024)}
  end

  defp incoming(files, allowed_roots) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{relative_path: rel, source_path: source}, {:ok, acc} when is_binary(source) ->
        with {:ok, rel} <- Ingest.validate_relative_path(rel),
             {:ok, size} <- contained_regular(source, allowed_roots),
             {:ok, sha} <- sha256(source) do
          {:cont,
           {:ok, [{%Item{relative_path: rel, source_path: source, bytes: size}, sha} | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.new(:path_invalid, "file needs relative_path and source_path", %{
            file: inspect(other)
          })}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  `{:ok, size}` when `path` is a regular file reachable under one of `roots` without
  crossing a symlink, else a `:path_invalid` / `:source_missing` error.
  """
  @spec contained_regular(String.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def contained_regular(path, roots) do
    expanded = Path.expand(path)

    case Enum.find(roots, &under?(expanded, Path.expand(&1))) do
      nil ->
        {:error,
         Error.new(:path_invalid, "#{path} is outside the allowed directories", %{path: path})}

      root ->
        with :ok <- no_symlinks(Path.expand(root), expanded) do
          case File.lstat(expanded) do
            {:ok, %File.Stat{type: :regular, size: size}} ->
              {:ok, size}

            _ ->
              {:error,
               Error.new(:source_missing, "#{path} is not a readable regular file", %{path: path})}
          end
        end
    end
  end

  defp under?(path, root), do: String.starts_with?(path, root <> "/")

  # Every path component below the root must be a real directory/file, not a link.
  defp no_symlinks(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, current} ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, Error.new(:path_invalid, "#{next} is a symlink", %{path: next})}}

        {:ok, _} ->
          {:cont, {:ok, next}}

        {:error, _} ->
          {:halt, {:error, Error.new(:source_missing, "#{next} does not exist", %{path: next})}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sha256(path) do
    hash =
      path
      |> File.stream!(@chunk)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  rescue
    error in File.Error ->
      {:error,
       Error.new(:source_missing, "cannot read #{path}: #{Exception.message(error)}", %{
         path: path
       })}
  end
end
