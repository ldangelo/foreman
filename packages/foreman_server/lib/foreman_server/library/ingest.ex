defmodule ForemanServer.Library.Ingest do
  @moduledoc """
  Turns a source into a validated `ForemanServer.Library.Plan` (no CQRS, no HTTP,
  no writes to the library).

  Sources:

    * `{:files, [%{relative_path:, source_path:}]}` - uploaded temp files or explicit
      paths. At most `max_files_per_add` files; any file over `max_file_bytes` fails
      the whole add (`:file_too_large`, naming the file).
    * `{:folder, abs_path}` - a server-local directory, walked depth-first in sorted
      order. Hidden files/directories and `node_modules` are skipped, symlinks are NOT
      followed (reported as skipped), files over `folder_skip_file_bytes` are skipped,
      then the first `folder_max_files` remaining files are taken until the next file
      would push the total over `folder_max_bytes`. Everything left out is reported
      with a reason; an empty selection is `:folder_empty`.
    * `{:folder_files, [%{relative_path:, source_path:}]}` - an uploaded folder (the
      client sends the tree as files with relative paths). Same eligibility and
      selection rules as `{:folder, path}`, applied to the relative paths; skipped
      entries carry the uploaded relative path.

  The mirrored Claude limits come from `config :foreman_server, :library`
  (`max_files_per_add`, `max_file_bytes`, `folder_max_files`, `folder_max_bytes`,
  `folder_skip_file_bytes`). Selection is deterministic: the same tree always
  yields the same plan.

  Relative paths are validated by `validate_relative_path/1`: empty, absolute,
  NUL-containing, `.`/`..`/empty segments and anything resolving outside the entry
  root are `:path_invalid`.
  """

  alias ForemanServer.Library.{Error, Plan}
  alias ForemanServer.Library.Plan.{Item, Skip}

  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_ -]{0,127}\z/

  @type file_source :: %{relative_path: String.t(), source_path: String.t()}
  @type source ::
          {:files, [file_source()]}
          | {:folder_files, [file_source()]}
          | {:folder, String.t()}

  @doc "Effective limits (config merged with `overrides`)."
  @spec limits(map() | keyword()) :: map()
  def limits(overrides \\ %{}) do
    config = Application.get_env(:foreman_server, :library, [])

    %{
      max_files_per_add: Keyword.get(config, :max_files_per_add, 100),
      max_file_bytes: Keyword.get(config, :max_file_bytes, 480 * 1024 * 1024),
      folder_max_files: Keyword.get(config, :folder_max_files, 100),
      folder_max_bytes: Keyword.get(config, :folder_max_bytes, 200 * 1024 * 1024),
      folder_skip_file_bytes: Keyword.get(config, :folder_skip_file_bytes, 30 * 1024 * 1024)
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc """
  Builds a plan. Options: `:name` (explicit entry name), `:limits` (map overriding
  the configured limits; used by tests).
  """
  @spec plan(source(), keyword()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def plan(source, opts \\ []) do
    limits = limits(Keyword.get(opts, :limits, %{}))
    explicit = Keyword.get(opts, :name)

    case source do
      {:files, files} when is_list(files) ->
        with {:ok, name} <- name(explicit, default_files_name(files)),
             {:ok, items} <- plan_files(files, limits) do
          {:ok, build(:file, name, items, [])}
        end

      {:folder, path} when is_binary(path) ->
        with {:ok, name} <- name(explicit, Path.basename(path)),
             {:ok, root} <- folder_root(path),
             {:ok, items, skipped} <- plan_folder(root, limits) do
          {:ok, build(:folder, name, items, skipped)}
        end

      {:folder_files, files} when is_list(files) ->
        with {:ok, name} <- name(explicit, "folder"),
             {:ok, items, skipped} <- plan_folder_files(files, limits) do
          {:ok, build(:folder, name, items, skipped)}
        end
    end
  end

  @doc "True when `name` is a valid entry name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  @doc """
  Validates an entry-relative path. Returns the normalised path (segments joined by
  `/`) or a `:path_invalid` error.
  """
  @spec validate_relative_path(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_relative_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      path == "" -> invalid(path, "empty path")
      String.contains?(path, <<0>>) -> invalid(path, "NUL in path")
      String.starts_with?(path, "/") -> invalid(path, "absolute path")
      String.contains?(path, "\\") -> invalid(path, "backslash in path")
      Enum.any?(segments, &(&1 in ["", ".", ".."])) -> invalid(path, "unsafe path segment")
      true -> contained(path)
    end
  end

  def validate_relative_path(path), do: invalid(inspect(path), "path must be a string")

  # Defence in depth: the segment check above already forbids `..`; this proves the
  # expanded path still sits under the root.
  defp contained(path) do
    root = Path.expand("/library-root")
    expanded = Path.expand(path, root)

    if String.starts_with?(expanded, root <> "/"),
      do: {:ok, path},
      else: invalid(path, "path escapes the entry root")
  end

  defp invalid(path, why),
    do: {:error, Error.new(:path_invalid, "invalid library path: #{why}", %{path: path})}

  # -- names -------------------------------------------------------------

  defp name(explicit, _default) when is_binary(explicit) do
    if valid_name?(explicit),
      do: {:ok, explicit},
      else:
        {:error,
         Error.new(
           :name_invalid,
           "entry name must match ^[A-Za-z0-9][A-Za-z0-9_ -]{0,127}$",
           %{name: explicit}
         )}
  end

  defp name(nil, default), do: {:ok, sanitize_name(default)}

  defp name(other, _default),
    do: {:error, Error.new(:name_invalid, "entry name must be a string", %{name: inspect(other)})}

  defp default_files_name([%{relative_path: rel}]) when is_binary(rel),
    do: rel |> Path.basename() |> Path.rootname()

  defp default_files_name(_), do: "files"

  defp sanitize_name(raw) do
    cleaned =
      raw
      |> String.replace(~r/[^A-Za-z0-9_ -]+/, "-")
      |> String.replace(~r/\A[^A-Za-z0-9]+/, "")
      |> String.slice(0, 128)

    if cleaned == "", do: "library-entry", else: cleaned
  end

  # -- files -------------------------------------------------------------

  defp plan_files(files, limits) do
    cond do
      files == [] ->
        {:error, Error.new(:source_missing, "no files supplied", %{})}

      length(files) > limits.max_files_per_add ->
        {:error,
         Error.new(
           :too_many_files,
           "at most #{limits.max_files_per_add} files per add (got #{length(files)})",
           %{max: limits.max_files_per_add, got: length(files)}
         )}

      true ->
        files
        |> Enum.reduce_while({:ok, [], MapSet.new()}, fn file, {:ok, acc, seen} ->
          case file_item(file, limits, seen) do
            {:ok, %Item{relative_path: rel} = item} ->
              {:cont, {:ok, [item | acc], MapSet.put(seen, rel)}}

            {:error, _} = error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, items, _seen} -> {:ok, Enum.sort_by(items, & &1.relative_path)}
          {:error, _} = error -> error
        end
    end
  end

  defp file_item(%{relative_path: rel, source_path: source}, limits, seen)
       when is_binary(source) do
    with {:ok, rel} <- validate_relative_path(rel),
         :ok <- ensure_unseen(rel, seen),
         {:ok, bytes} <- regular_size(source, rel),
         :ok <- ensure_file_size(rel, bytes, limits) do
      {:ok, %Item{relative_path: rel, source_path: source, bytes: bytes}}
    end
  end

  defp file_item(other, _limits, _seen),
    do: invalid(inspect(other), "file needs relative_path and source_path")

  defp ensure_unseen(rel, seen) do
    if MapSet.member?(seen, rel), do: invalid(rel, "duplicate path in this add"), else: :ok
  end

  defp regular_size(source, rel) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, size}

      {:ok, %File.Stat{type: type}} ->
        {:error,
         Error.new(:source_missing, "#{rel} is not a regular file (#{type})", %{path: rel})}

      {:error, reason} ->
        {:error,
         Error.new(:source_missing, "cannot read #{rel}: #{inspect(reason)}", %{path: rel})}
    end
  end

  defp ensure_file_size(rel, bytes, limits) do
    if bytes > limits.max_file_bytes do
      {:error,
       Error.new(
         :file_too_large,
         "#{rel} is #{bytes} bytes; the per-file limit is #{limits.max_file_bytes}",
         %{path: rel, bytes: bytes, max: limits.max_file_bytes}
       )}
    else
      :ok
    end
  end

  # An uploaded folder: the client sends the tree as files with relative paths. The
  # same eligibility and selection rules as a server-local folder apply (the server
  # stays authoritative whatever the client filtered).
  defp plan_folder_files(files, limits) do
    with {:ok, items} <- folder_file_items(files) do
      {eligible, skipped} =
        Enum.reduce(items, {[], []}, fn %Item{relative_path: rel, bytes: size} = item,
                                        {ok, skip} ->
          segments = String.split(rel, "/")

          cond do
            Enum.any?(segments, &String.starts_with?(&1, ".")) ->
              {ok, [%Skip{path: rel, reason: :hidden} | skip]}

            "node_modules" in segments ->
              {ok, [%Skip{path: rel, reason: :node_modules} | skip]}

            size > limits.folder_skip_file_bytes ->
              {ok, [%Skip{path: rel, reason: :over_30mb} | skip]}

            true ->
              {[item | ok], skip}
          end
        end)

      {selected, over} = select(Enum.reverse(eligible), limits)
      skipped = Enum.reverse(skipped) ++ over

      if selected == [] do
        {:error,
         Error.new(:folder_empty, "folder has no eligible files", %{
           skipped: Plan.skipped_summary(skipped)
         })}
      else
        {:ok, selected, skipped}
      end
    end
  end

  defp folder_file_items(files) do
    files
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      %{relative_path: rel, source_path: source}, {:ok, acc, seen} when is_binary(source) ->
        with {:ok, rel} <- validate_relative_path(rel),
             :ok <- ensure_unseen(rel, seen),
             {:ok, size} <- regular_size(source, rel) do
          item = %Item{relative_path: rel, source_path: source, bytes: size}
          {:cont, {:ok, [item | acc], MapSet.put(seen, rel)}}
        else
          {:error, _} = error -> {:halt, error}
        end

      other, _acc ->
        {:halt, invalid(inspect(other), "file needs relative_path and source_path")}
    end)
    |> case do
      {:ok, items, _seen} -> {:ok, Enum.sort_by(items, & &1.relative_path)}
      error -> error
    end
  end

  # -- folders -----------------------------------------------------------

  defp folder_root(path) do
    cond do
      Path.type(path) != :absolute ->
        {:error, Error.new(:path_invalid, "folder path must be absolute", %{path: path})}

      String.contains?(path, <<0>>) ->
        {:error, Error.new(:path_invalid, "NUL in folder path", %{path: path})}

      true ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            {:ok, Path.expand(path)}

          _ ->
            {:error, Error.new(:source_missing, "not a directory: #{path}", %{path: path})}
        end
    end
  end

  defp plan_folder(root, limits) do
    {candidates, skipped} = walk(root, "", {[], []}, limits)
    candidates = Enum.reverse(candidates)
    {items, over} = select(candidates, limits)
    skipped = Enum.reverse(skipped) ++ over

    if items == [] do
      {:error,
       Error.new(:folder_empty, "folder has no eligible files", %{
         skipped: Plan.skipped_summary(skipped)
       })}
    else
      {:ok, items, skipped}
    end
  end

  # Depth-first, sorted at every level, symlinks never followed.
  defp walk(root, rel_dir, acc, limits) do
    dir = if rel_dir == "", do: root, else: Path.join(root, rel_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, acc ->
          rel = if rel_dir == "", do: name, else: rel_dir <> "/" <> name
          walk_entry(root, rel, name, acc, limits)
        end)

      {:error, _} ->
        add_skip(acc, rel_dir, :not_regular)
    end
  end

  defp walk_entry(root, rel, name, acc, limits) do
    case File.lstat(Path.join(root, rel)) do
      {:ok, %File.Stat{type: :symlink}} ->
        add_skip(acc, rel, :symlink)

      {:ok, %File.Stat{type: :directory}} ->
        cond do
          String.starts_with?(name, ".") -> add_skip(acc, rel, :hidden)
          name == "node_modules" -> add_skip(acc, rel, :node_modules)
          true -> walk(root, rel, acc, limits)
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        cond do
          String.starts_with?(name, ".") -> add_skip(acc, rel, :hidden)
          size > limits.folder_skip_file_bytes -> add_skip(acc, rel, :over_30mb)
          true -> add_candidate(acc, root, rel, size)
        end

      _ ->
        add_skip(acc, rel, :not_regular)
    end
  end

  defp add_candidate({cands, skipped}, root, rel, size),
    do:
      {[%Item{relative_path: rel, source_path: Path.join(root, rel), bytes: size} | cands],
       skipped}

  defp add_skip({cands, skipped}, rel, reason),
    do: {cands, [%Skip{path: rel, reason: reason} | skipped]}

  # First `folder_max_files` files; stop at the first file that would exceed the byte
  # budget (everything after it is reported as over budget, so selection stays a
  # strict prefix of the sorted order).
  defp select(candidates, limits) do
    {taken, _bytes, over, _closed?} =
      Enum.reduce(candidates, {[], 0, [], false}, fn item, {taken, bytes, over, closed?} ->
        cond do
          length(taken) >= limits.folder_max_files ->
            {taken, bytes, [skip(item, :folder_file_cap) | over], closed?}

          closed? or bytes + item.bytes > limits.folder_max_bytes ->
            {taken, bytes, [skip(item, :folder_byte_budget) | over], true}

          true ->
            {[item | taken], bytes + item.bytes, over, closed?}
        end
      end)

    {Enum.reverse(taken), Enum.reverse(over)}
  end

  defp skip(%Item{relative_path: rel}, reason), do: %Skip{path: rel, reason: reason}

  defp build(kind, name, items, skipped) do
    %Plan{
      kind: kind,
      name: name,
      files: items,
      skipped: skipped,
      total_bytes: Enum.reduce(items, 0, &(&1.bytes + &2))
    }
  end
end
