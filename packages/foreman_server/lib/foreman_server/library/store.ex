defmodule ForemanServer.Library.Store do
  @moduledoc """
  On-disk layout of a project's library, rooted at `<project path>/.foreman/library/`.

      <entry_id>/entry.json        schema foreman.library.entry.v1 (name, kind, source,
                                   files[{path,bytes,sha256}], skipped, manifest_sha256)
      <entry_id>/files/<path...>   the copied files, read-only (0444, dirs 0555)

  `entry_id` is a stable slug (`slug(name) <> "-" <> short random`).

  Writes are atomic from a reader's point of view: files are streamed (`copy` +
  incremental sha256, never read whole into memory) into a hidden
  `.staging-<uuid>` directory, made read-only, then swapped in with a rename. A
  replaced or removed entry is first moved to `.trash-<uuid>`; the caller then
  `commit/1`s (delete the trash) or `rollback/2`s (restore it) depending on whether
  the metadata command succeeded. `.staging-*`/`.trash-*` directories are invisible
  to `list/1` and are swept by `sweep/2` once older than the given age.

  Read-only mode is advisory on the host (agents run as the same OS user); the
  docker sandbox mounts the directory `:ro`, which is the real guarantee.
  """

  alias ForemanServer.ForemanDir
  alias ForemanServer.Library.{Entry, Error, Ingest, Plan}
  alias ForemanServer.Library.Plan.Item

  require Logger

  @chunk 65_536

  defmodule Pending do
    @moduledoc "Disk state to finish (`commit/1`) or undo (`rollback/1`) after the metadata command."
    @enforce_keys [:root, :entry_id]
    @type t :: %__MODULE__{
            root: String.t(),
            entry_id: String.t(),
            trash: String.t() | nil,
            wrote?: boolean()
          }
    defstruct [:root, :entry_id, :trash, wrote?: false]
  end

  @doc "The library root for a project checkout."
  @spec root(String.t()) :: String.t()
  def root(project_path), do: Path.join([project_path, ".foreman", "library"])

  @doc """
  Creates the library root and gitignores `library/` (ONLY that path; the other
  `.foreman/` files are tracked project configuration).
  """
  @spec ensure_ready(String.t()) :: :ok | {:error, Error.t()}
  def ensure_ready(project_path) do
    with :ok <- gitignore(project_path),
         :ok <- fs(File.mkdir_p(root(project_path)), "create library root") do
      :ok
    end
  end

  defp gitignore(project_path) do
    case ForemanDir.ensure_ignored(project_path, "library/") do
      :ok ->
        :ok

      {:error, %ForemanDir.Error{message: message, details: details}} ->
        {:error, Error.new(:write_failed, "cannot gitignore library: #{message}", details)}
    end
  end

  @doc "A new entry id for `name`."
  @spec new_entry_id(String.t()) :: String.t()
  def new_entry_id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if(slug == "", do: "entry", else: slug) <> "-" <> short_random()
  end

  @doc """
  Writes `plan` as entry `entry_id`. With `replace?: true` an existing entry is moved
  to the trash (its `created_at` is preserved) and the returned `Pending` must be
  resolved with `commit/1` or `rollback/1`. Options: `:source` (map stored in
  `entry.json`), `:replace?`.
  """
  @spec write(String.t(), String.t(), Plan.t(), keyword()) ::
          {:ok, Entry.t(), Pending.t()} | {:error, Error.t()}
  def write(root, entry_id, %Plan{} = plan, opts \\ []) do
    replace? = Keyword.get(opts, :replace?, false)
    final = entry_dir(root, entry_id)
    staging = Path.join(root, ".staging-" <> short_random())

    with :ok <- fs(File.mkdir_p(Path.join(staging, "files")), "create staging"),
         {:ok, files} <- copy_all(plan.files, Path.join(staging, "files")),
         {:ok, previous} <- previous(root, entry_id, replace?),
         entry = build_entry(entry_id, plan, files, previous, Keyword.get(opts, :source, %{})),
         :ok <- write_entry_json(staging, entry),
         :ok <- lock_down(staging),
         {:ok, trash} <- move_aside(root, final, replace?),
         :ok <- swap_in(staging, final, trash) do
      {:ok, entry, %Pending{root: root, entry_id: entry_id, trash: trash, wrote?: true}}
    else
      {:error, %Error{}} = error ->
        discard(staging)
        error
    end
  end

  @doc "Moves an entry to the trash. Resolve the result with `commit/1` or `rollback/1`."
  @spec remove(String.t(), String.t()) :: {:ok, Entry.t(), Pending.t()} | {:error, Error.t()}
  def remove(root, entry_id) do
    with {:ok, entry} <- read_entry(root, entry_id),
         {:ok, trash} <- move_aside(root, entry_dir(root, entry_id), true) do
      {:ok, entry, %Pending{root: root, entry_id: entry_id, trash: trash}}
    end
  end

  @doc "Deletes the trashed previous version."
  @spec commit(Pending.t()) :: :ok
  def commit(%Pending{trash: nil}), do: :ok
  def commit(%Pending{trash: trash}), do: discard(trash)

  @doc "Undoes a write/remove: drops what was written and restores the trashed entry."
  @spec rollback(Pending.t()) :: :ok
  def rollback(%Pending{root: root, entry_id: entry_id, trash: trash, wrote?: wrote?}) do
    final = entry_dir(root, entry_id)
    if wrote?, do: discard(final)

    if is_binary(trash) do
      case File.rename(trash, final) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("library rollback of #{entry_id} failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Every entry on disk, sorted by name. Unreadable entry.json files are skipped."
  @spec list(String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(root) do
    case File.ls(root) do
      {:ok, names} ->
        entries =
          names
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.flat_map(fn id ->
            case read_entry(root, id) do
              {:ok, entry} -> [entry]
              {:error, _} -> []
            end
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, Error.new(:write_failed, "cannot list library: #{inspect(reason)}")}
    end
  end

  @doc "One entry from its `entry.json`."
  @spec read_entry(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def read_entry(root, entry_id) do
    with :ok <- check_id(entry_id),
         {:ok, raw} <- File.read(Path.join(entry_dir(root, entry_id), "entry.json")),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, entry} <- Entry.from_json_map(decoded) do
      {:ok, entry}
    else
      _ -> {:error, not_found(entry_id)}
    end
  end

  @doc "Absolute path of the entry's `files/` directory (the agent-visible location)."
  @spec files_dir(String.t(), String.t()) :: String.t()
  def files_dir(root, entry_id), do: Path.join(entry_dir(root, entry_id), "files")

  @doc """
  Reads one file of an entry (at most `max_bytes`). `rel` is validated entry-relative;
  only regular files inside `files/` are readable.
  """
  @spec read_file(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_file(root, entry_id, rel, max_bytes) do
    with :ok <- check_id_or_not_found(entry_id),
         {:ok, rel} <- Ingest.validate_relative_path(rel),
         path = Path.join(files_dir(root, entry_id), rel),
         :ok <- no_symlink_components(files_dir(root, entry_id), rel),
         {:ok, %File.Stat{type: :regular, size: size}} <- lstat_or_not_found(path, rel),
         :ok <- ensure_readable_size(size, max_bytes, rel) do
      case File.read(path) do
        {:ok, bytes} ->
          {:ok, bytes}

        {:error, reason} ->
          {:error, Error.new(:write_failed, "cannot read #{rel}: #{inspect(reason)}")}
      end
    else
      {:ok, %File.Stat{}} -> {:error, not_found(rel)}
      {:error, %Error{}} = error -> error
    end
  end

  # Every component below `files/` must be a real directory/file: a symlinked
  # parent would let `a/link/secret` read outside the entry even though the final
  # component is a regular file.
  defp no_symlink_components(base, rel) do
    rel
    |> Path.split()
    |> Enum.reduce_while(base, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, :symlink}
        {:ok, _} -> {:cont, next}
        {:error, _} -> {:halt, :missing}
      end
    end)
    |> case do
      :symlink -> {:error, not_found(rel)}
      :missing -> {:error, not_found(rel)}
      _ok -> :ok
    end
  end

  @doc "Deletes `.staging-*` / `.trash-*` directories older than `max_age_seconds`."
  @spec sweep(String.t(), non_neg_integer()) :: :ok
  def sweep(root, max_age_seconds) do
    case File.ls(root) do
      {:ok, names} ->
        cutoff = System.os_time(:second) - max_age_seconds

        for name <- names, orphan?(name), path = Path.join(root, name), old?(path, cutoff) do
          discard(path)
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  # -- internals -----------------------------------------------------------

  defp orphan?(name),
    do: String.starts_with?(name, ".staging-") or String.starts_with?(name, ".trash-")

  defp old?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime <= cutoff
      {:error, _} -> false
    end
  end

  defp entry_dir(root, entry_id), do: Path.join(root, entry_id)

  defp check_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,127}\z/, id), do: :ok, else: :error
  end

  defp check_id(_), do: :error

  defp check_id_or_not_found(id) do
    case check_id(id) do
      :ok -> :ok
      :error -> {:error, not_found(to_string(id))}
    end
  end

  defp lstat_or_not_found(path, rel) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _} -> {:error, not_found(rel)}
    end
  end

  defp ensure_readable_size(size, max_bytes, rel) do
    if size > max_bytes do
      {:error,
       Error.new(:too_large, "#{rel} is #{size} bytes; read at most #{max_bytes}", %{
         path: rel,
         bytes: size,
         max: max_bytes
       })}
    else
      :ok
    end
  end

  defp not_found(what), do: Error.new(:not_found, "not found: #{what}", %{id: what})

  defp copy_all(items, dest_root) do
    items
    |> Enum.reduce_while({:ok, []}, fn %Item{} = item, {:ok, acc} ->
      case copy_one(item, dest_root) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.sort_by(files, & &1.path)}
      error -> error
    end
  end

  # Streams in fixed chunks; the digest and byte count describe what was actually
  # copied, so a source that changes mid-copy cannot disagree with its manifest.
  defp copy_one(%Item{relative_path: rel, source_path: source}, dest_root) do
    dest = Path.join(dest_root, rel)

    with :ok <- fs(File.mkdir_p(Path.dirname(dest)), "create #{Path.dirname(rel)}"),
         {:ok, bytes, sha} <- stream_copy(source, dest, rel) do
      {:ok, %{path: rel, bytes: bytes, sha256: sha}}
    end
  end

  defp stream_copy(source, dest, rel) do
    File.open(dest, [:write, :binary], fn out ->
      source
      |> File.stream!(@chunk)
      |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn chunk, {n, hash} ->
        IO.binwrite(out, chunk)
        {n + byte_size(chunk), :crypto.hash_update(hash, chunk)}
      end)
    end)
    |> case do
      {:ok, {bytes, hash}} ->
        {:ok, bytes, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, Error.new(:write_failed, "cannot copy #{rel}: #{inspect(reason)}", %{path: rel})}
    end
  rescue
    error in File.Error ->
      {:error,
       Error.new(:write_failed, "cannot copy #{rel}: #{Exception.message(error)}", %{path: rel})}
  end

  defp previous(_root, _id, false), do: {:ok, nil}

  defp previous(root, id, true) do
    case read_entry(root, id) do
      {:ok, entry} -> {:ok, entry}
      {:error, _} -> {:ok, nil}
    end
  end

  defp build_entry(entry_id, plan, files, previous, source) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %Entry{
      entry_id: entry_id,
      name: plan.name,
      kind: plan.kind,
      source: source,
      files: files,
      skipped: Enum.map(plan.skipped, &%{path: &1.path, reason: Atom.to_string(&1.reason)}),
      file_count: length(files),
      bytes: Enum.reduce(files, 0, &(&1.bytes + &2)),
      manifest_sha256: Entry.manifest_sha256(files),
      created_at: if(previous, do: previous.created_at, else: now),
      replaced_at: if(previous, do: now)
    }
  end

  defp write_entry_json(staging, entry) do
    json = entry |> Entry.to_json_map() |> Jason.encode!(pretty: true)
    fs(File.write(Path.join(staging, "entry.json"), json), "write entry.json")
  end

  # files 0444, directories 0555, deepest first so a parent stays traversable while
  # its children are changed.
  defp lock_down(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, names} <- File.ls(path),
             :ok <- reduce_ok(names, &lock_down(Path.join(path, &1))) do
          fs(File.chmod(path, 0o555), "chmod #{Path.basename(path)}")
        else
          {:error, %Error{}} = error ->
            error

          {:error, reason} ->
            {:error, Error.new(:write_failed, "lock down failed: #{inspect(reason)}")}
        end

      {:ok, %File.Stat{type: :regular}} ->
        fs(File.chmod(path, 0o444), "chmod #{Path.basename(path)}")

      _ ->
        :ok
    end
  end

  defp reduce_ok(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp move_aside(_root, _final, false), do: {:ok, nil}

  defp move_aside(root, final, true) do
    trash = Path.join(root, ".trash-" <> short_random())

    case File.rename(final, trash) do
      :ok ->
        {:ok, trash}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, Error.new(:write_failed, "cannot move old entry aside: #{inspect(reason)}")}
    end
  end

  defp swap_in(staging, final, trash) do
    case File.rename(staging, final) do
      :ok ->
        :ok

      {:error, reason} ->
        if trash, do: File.rename(trash, final)
        {:error, Error.new(:write_failed, "cannot move entry into place: #{inspect(reason)}")}
    end
  end

  # Read-only trees cannot be removed until their directories are writable again.
  defp discard(path) do
    make_writable(path)
    File.rm_rf(path)
    :ok
  end

  defp make_writable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(path, 0o755)

        case File.ls(path) do
          {:ok, names} -> Enum.each(names, &make_writable(Path.join(path, &1)))
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp fs(:ok, _what), do: :ok

  defp fs({:error, reason}, what),
    do:
      {:error,
       Error.new(:write_failed, "cannot #{what}: #{inspect(reason)}", %{reason: inspect(reason)})}

  defp short_random, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
