defmodule ForemanServer.RunArtifacts do
  @moduledoc """
  The bodies of `GET /api/runs/:id/artifacts` and `GET /api/runs/:id/artifacts/:phase_id`: the
  report file each completed phase of a run recorded, and the content of one of them.

  A typed projection of the phase read model, like `ForemanServer.RunPhases`. The listing
  (`list/2`) names the artifacts and never reads a file. The single-artifact body (`read/3`)
  reads **only the path the projection recorded for that phase**: `phase_id` is matched against
  the run's own phases and never becomes part of a path, so a client cannot steer the read.

  The read is capped at 262144 bytes (256 KiB, `max_content_bytes/0`). A longer file is cut on a UTF-8
  boundary and flagged `truncated`; invalid bytes are replaced with U+FFFD, and the cap applies
  to the returned content. `sha_matches` always covers the **whole** file: the file is streamed
  through the hash in 64 KiB chunks, so a truncated read still verifies the recorded `sha256`
  without holding the file in memory.

  The file is data, not an error, when it is gone or unreadable: `state` is `"missing"` or
  `"unreadable"`, `content` is `null` and `error` says why. A broken projection (a phase missing
  an identifying field, or an artifact without a string path) raises instead of turning into a
  quiet `artifact_not_found`.

  ## The archive

  The recorded path usually lies inside the run's git worktree (`{task.projectReportsDir}`), which
  is reclaimed once the run is over, so the report is also kept where the run's own files live:
  `archive_path/3` is `<artifact_base>/<run_id>/archive/phase-<index>.md`, under
  `ForemanServer.Workflow.RunExecutor.artifact_base/0` (`~/.foreman/runs`). The path is derived
  only from the run id (`UnsafeRunId` is raised for one that cannot name a directory) and the
  integer phase index, never from anything a client sent.

    * `archive/5` is the one writer. `RunExecutor.phase_finish/5` calls it when a phase completes
      and `ForemanServer.RunArtifacts.Backfill` calls it once at boot for the reports recorded
      before the archive existed. It copies the recorded file in one streamed pass, hashing what
      it copies, and keeps the copy only when that digest equals the recorded `sha256`: an
      archived report is exactly the bytes the phase recorded, or there is none. The copy goes to
      a temporary file in the archive directory and is renamed into place, so a reader never sees
      half a file and a retried phase replaces its earlier copy whole.
    * `read/3` reads the recorded file first and it always wins. Only when that file does not
      exist does it serve the archive copy: `state` `"ok"`, `sha_matches` judged against the same
      recorded digest, `source` `"archive"`. `source` is `"recorded"` in every other body, a
      `"missing"` one included (no archive copy either).
  """

  require Logger

  alias ForemanServer.Workflow.RunExecutor

  @archive_dir "archive"
  @max_content_bytes 262_144
  @chunk_bytes 65_536

  defmodule Entry do
    @moduledoc "One phase artifact of the listing: where it is and what it should hash to."

    @enforce_keys [:phase_id, :index, :name, :attempt, :status, :path, :sha256, :bytes]
    @type t :: %__MODULE__{
            phase_id: String.t(),
            index: integer(),
            name: String.t(),
            attempt: pos_integer(),
            status: String.t(),
            path: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer()
          }
    @derive Jason.Encoder
    defstruct [:phase_id, :index, :name, :attempt, :status, :path, :sha256, :bytes]
  end

  defmodule Content do
    @moduledoc """
    One phase artifact with the state of its file and, when readable, its content.

    `source` says which file the content was read from: `"recorded"` (the path the phase
    recorded) or `"archive"` (that file is gone and the copy kept at phase completion was read
    instead). `path` is always the recorded path.
    """

    @enforce_keys [
      :run_id,
      :phase_id,
      :index,
      :name,
      :path,
      :sha256,
      :bytes,
      :state,
      :source,
      :content,
      :content_bytes,
      :truncated,
      :sha_matches,
      :error
    ]
    @type state :: String.t()
    @type source :: String.t()
    @type t :: %__MODULE__{
            run_id: String.t(),
            phase_id: String.t(),
            index: integer(),
            name: String.t(),
            path: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer(),
            state: state(),
            source: source(),
            content: String.t() | nil,
            content_bytes: non_neg_integer(),
            truncated: boolean(),
            sha_matches: boolean() | nil,
            error: String.t() | nil
          }
    @derive Jason.Encoder
    defstruct [
      :run_id,
      :phase_id,
      :index,
      :name,
      :path,
      :sha256,
      :bytes,
      :state,
      :source,
      :content,
      :content_bytes,
      :truncated,
      :sha_matches,
      :error
    ]
  end

  defmodule UnsafeRunId do
    @moduledoc """
    Raised for a run id that cannot name a directory (empty, `.`, `..`, or holding a path
    separator or a control character) before any archive path is built from it.

    Run ids come from the projection, never from a client, so this is a corrupted identity and
    not bad input: it stops the caller instead of letting the id steer a read or a write outside
    the run's own directory.
    """

    @enforce_keys [:run_id, :reason]
    @type t :: %__MODULE__{run_id: String.t(), reason: String.t()}
    defexception [:run_id, :reason]

    @impl true
    def message(%__MODULE__{run_id: run_id, reason: reason}),
      do: "run id #{inspect(run_id)} cannot name an archive directory: #{reason}"
  end

  @enforce_keys [:run_id, :artifacts]
  @type t :: %__MODULE__{run_id: String.t(), artifacts: [Entry.t()]}
  @derive Jason.Encoder
  defstruct [:run_id, :artifacts]

  @doc "The cap, in bytes, on the content `read/3` returns."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @doc """
  Builds the listing from the phase projections of `run_id`, in the order given: only the
  phases that recorded an artifact appear.
  """
  @spec list(String.t(), [map()]) :: t()
  def list(run_id, phase_projections) when is_binary(run_id) and is_list(phase_projections) do
    entries =
      for projection <- phase_projections,
          artifact = artifact(projection),
          do: entry(projection, artifact)

    %__MODULE__{run_id: run_id, artifacts: entries}
  end

  @doc """
  Reads the artifact `phase_id` of the run described by `phase_projections`.

  The recorded file is read first and wins whenever it exists. Only when it does not (`:enoent`)
  is the run's archive copy of that phase read in its place (`source` `"archive"`); with neither
  the body is `state` `"missing"`. `{:error, :phase_not_found}`: the run has no such phase.
  `{:error, :artifact_not_found}`: the phase recorded no artifact.

  Looking for the archive copy raises `UnsafeRunId` for a run id that cannot be a directory name.
  """
  @spec read(String.t(), String.t(), [map()]) ::
          {:ok, Content.t()} | {:error, :phase_not_found | :artifact_not_found}
  def read(run_id, phase_id, phase_projections)
      when is_binary(run_id) and is_binary(phase_id) and is_list(phase_projections) do
    case Enum.find(phase_projections, &(Map.fetch!(&1, :phase_id) == phase_id)) do
      nil ->
        {:error, :phase_not_found}

      projection ->
        case artifact(projection) do
          nil -> {:error, :artifact_not_found}
          artifact -> {:ok, content(run_id, projection, artifact)}
        end
    end
  end

  @typedoc """
  Why `archive/5` kept no copy. `:recorded_missing` is the ordinary end of a report whose
  worktree was reclaimed; every other reason is a failure that `warn_not_archived/4` makes loud.
  """
  @type archive_error ::
          :recorded_missing
          | {:recorded_unreadable, :file.posix() | :badarg | :terminated}
          | {:sha_mismatch, expected :: String.t(), actual :: String.t()}
          | {:archive_unwritable, :file.posix() | :badarg | :terminated}

  @doc """
  Where phase `index` of run `run_id` keeps its archive copy under `artifact_base`
  (`RunExecutor.artifact_base/0`, or the executor state's `artifact_base`):
  `<artifact_base>/<run_id>/archive/phase-<index>.md`.

  The one place the layout is spelled: the writer, the read fallback and the boot backfill all
  go through it. Raises `UnsafeRunId` for a run id that cannot be a directory name.
  """
  @spec archive_path(String.t(), String.t(), integer()) :: Path.t()
  def archive_path(artifact_base, run_id, index)
      when is_binary(artifact_base) and is_binary(run_id) and is_integer(index) do
    assert_safe_run_id!(run_id)
    Path.join([artifact_base, run_id, @archive_dir, "phase-#{index}.md"])
  end

  @doc """
  Keeps a copy of the report `recorded_path` of phase `index` of run `run_id` at its
  `archive_path/3`, but only when the bytes hash to `recorded_sha256`.

  The file is read once, in chunks: each chunk is hashed and written to a temporary file in the
  archive directory, and the temporary file is renamed over the archive path only after the
  digest matched. A mismatch, a failed read or a failed write leaves nothing behind and an
  archive copy from an earlier attempt of the same phase untouched; a success replaces that
  earlier copy whole.

    * `{:ok, path}`: the copy is at `path`.
    * `:in_archive`: `recorded_path` already lies inside the run's archive directory; nothing was
      copied.
    * `{:error, reason}`: nothing was archived (`t:archive_error/0`).

  Raises `UnsafeRunId` for a run id that cannot be a directory name.
  """
  @spec archive(String.t(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, Path.t()} | :in_archive | {:error, archive_error()}
  def archive(artifact_base, run_id, index, recorded_path, recorded_sha256)
      when is_binary(artifact_base) and is_binary(run_id) and is_integer(index) and
             is_binary(recorded_path) and is_binary(recorded_sha256) do
    dest = archive_path(artifact_base, run_id, index)

    if within?(recorded_path, Path.dirname(dest)) do
      :in_archive
    else
      copy_verified(recorded_path, dest, String.downcase(recorded_sha256))
    end
  end

  @doc """
  Logs at warning level that the report `recorded_path` of phase `index` of run `run_id` was not
  archived, and why. The one message every caller of `archive/5` uses for a failure it did not
  expect, a digest mismatch (both hashes named) included.
  """
  @spec warn_not_archived(String.t(), integer(), String.t(), archive_error()) :: :ok
  def warn_not_archived(run_id, index, recorded_path, reason) do
    Logger.warning(
      "run #{run_id} phase #{index}: report #{recorded_path} was not archived: " <>
        explain(reason)
    )
  end

  # A phase that never completed has `artifact: nil` (or no key at all in an older projection).
  # A recorded artifact must carry a string path: anything else is a broken read model.
  defp artifact(projection) do
    case Map.get(projection, :artifact) do
      nil -> nil
      %{path: path} = artifact when is_binary(path) -> artifact
    end
  end

  defp entry(p, artifact) do
    %Entry{
      phase_id: Map.fetch!(p, :phase_id),
      index: Map.fetch!(p, :index),
      name: Map.fetch!(p, :name),
      attempt: Map.fetch!(p, :attempt),
      status: Map.fetch!(p, :status),
      path: artifact.path,
      sha256: Map.fetch!(artifact, :sha256),
      bytes: Map.fetch!(artifact, :bytes)
    }
  end

  defp content(run_id, p, artifact) do
    base = %Content{
      run_id: run_id,
      phase_id: Map.fetch!(p, :phase_id),
      index: Map.fetch!(p, :index),
      name: Map.fetch!(p, :name),
      path: artifact.path,
      sha256: Map.fetch!(artifact, :sha256),
      bytes: Map.fetch!(artifact, :bytes),
      state: "ok",
      source: "recorded",
      content: nil,
      content_bytes: 0,
      truncated: false,
      sha_matches: nil,
      error: nil
    }

    case read_capped(artifact.path) do
      {:error, :enoent} ->
        content_from_archive(base)

      {:ok, _head, _total_bytes, digest} = read ->
        if digest == String.downcase(base.sha256),
          do: served(base, read),
          else: changed_on_disk(base, read)

      read ->
        served(base, read)
    end
  end

  # The recorded file is gone (its worktree was reclaimed): the copy kept at phase completion is
  # the report, judged against the same recorded digest. Without a copy the artifact is gone.
  defp content_from_archive(%Content{} = base) do
    path = archive_path(RunExecutor.artifact_base(), base.run_id, base.index)

    case read_capped(path) do
      {:error, :enoent} ->
        %Content{base | state: "missing", error: "no such file: the artifact is gone"}

      read ->
        served(%Content{base | source: "archive"}, read)
    end
  end

  # The recorded file exists but is no longer what the phase wrote (a later run of the task or a
  # commit overwrote the shared report path). The archive copy, when it matches the recorded
  # digest, is the report; otherwise the file on disk is shown and its own digest says it differs.
  defp changed_on_disk(%Content{} = base, recorded_read) do
    case read_capped(archive_path(RunExecutor.artifact_base(), base.run_id, base.index)) do
      {:ok, _head, _total_bytes, digest} = copy ->
        if digest == String.downcase(base.sha256),
          do: served(%Content{base | source: "archive"}, copy),
          else: served(base, recorded_read)

      _no_usable_copy ->
        served(base, recorded_read)
    end
  end

  defp served(%Content{} = base, {:ok, head, total_bytes, digest}) do
    {text, truncated?} = to_content(head, total_bytes)

    %Content{
      base
      | content: text,
        content_bytes: byte_size(text),
        truncated: truncated?,
        sha_matches: digest == String.downcase(base.sha256)
    }
  end

  defp served(%Content{} = base, {:error, reason}),
    do: %Content{base | state: "unreadable", error: reason_string(reason)}

  # Streams the whole file once: hashes every chunk and keeps the first `@max_content_bytes + 4`
  # bytes (the extra bytes let `to_content/2` see what follows the cut).
  defp read_capped(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          loop(io, :crypto.hash_init(:sha256), [], 0, 0)
        after
          File.close(io)
        end

      {:error, _} = error ->
        error
    end
  end

  defp loop(io, hash, head, head_size, total) do
    case IO.binread(io, @chunk_bytes) do
      :eof ->
        {:ok, IO.iodata_to_binary(head), total,
         hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, _} = error ->
        error

      data when is_binary(data) ->
        hash = :crypto.hash_update(hash, data)
        keep = max(0, min(byte_size(data), @max_content_bytes + 4 - head_size))
        head = if keep > 0, do: [head, binary_part(data, 0, keep)], else: head
        loop(io, hash, head, head_size + keep, total + byte_size(data))
    end
  end

  # Cuts the raw head at the cap on a UTF-8 boundary, replaces invalid bytes (which can grow
  # the text) and cuts again if replacement pushed it over the cap.
  defp to_content(head, total_bytes) do
    raw = cut_utf8(head, @max_content_bytes)
    full = String.replace_invalid(raw)
    text = cut_utf8(full, @max_content_bytes)
    {text, total_bytes > byte_size(raw) or byte_size(text) < byte_size(full)}
  end

  # Longest prefix of `bin` of at most `max` bytes that does not end inside a character: when
  # the byte just after the cut is a continuation byte, back off to the character's lead byte.
  defp cut_utf8(bin, max) when byte_size(bin) <= max, do: bin

  defp cut_utf8(bin, max) do
    pos = back_off(bin, max)
    binary_part(bin, 0, pos)
  end

  defp back_off(_bin, 0), do: 0

  defp back_off(bin, pos) do
    if Bitwise.band(:binary.at(bin, pos), 0xC0) == 0x80, do: back_off(bin, pos - 1), else: pos
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  # A run id becomes a directory name. It comes from the projection, never from a client, but one
  # that is empty, a traversal segment, or holds a separator or a control character must not
  # steer a read or a write outside the run's own directory.
  defp assert_safe_run_id!(run_id) do
    cond do
      run_id == "" ->
        unsafe_run_id!(run_id, "empty")

      run_id in [".", ".."] ->
        unsafe_run_id!(run_id, "traversal segment")

      String.contains?(run_id, ["/", "\\"]) ->
        unsafe_run_id!(run_id, "contains a path separator")

      String.match?(run_id, ~r/[\x00-\x1F\x7F]/) ->
        unsafe_run_id!(run_id, "contains a control character")

      true ->
        :ok
    end
  end

  defp unsafe_run_id!(run_id, reason), do: raise(UnsafeRunId, run_id: run_id, reason: reason)

  # Whether `path` lies inside `dir`, lexically: `..` and `~` are resolved, symlinks are not.
  defp within?(path, dir), do: String.starts_with?(Path.expand(path), Path.expand(dir) <> "/")

  # Copies `source` to `dest` through a temporary file in `dest`'s directory and renames it into
  # place only when the copied bytes hash to `expected`. The source is opened first, so a report
  # that is gone or unreadable creates nothing at all.
  defp copy_verified(source, dest, expected) do
    case File.open(source, [:read, :binary]) do
      {:ok, input} ->
        try do
          publish(input, dest, expected)
        after
          File.close(input)
        end

      {:error, :enoent} ->
        {:error, :recorded_missing}

      {:error, reason} ->
        {:error, {:recorded_unreadable, reason}}
    end
  end

  # Whatever fails after the source was opened, the temporary file goes.
  defp publish(input, dest, expected) do
    tmp = "#{dest}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- make_dir(Path.dirname(dest)),
         {:ok, actual} <- copy_hashing(input, tmp),
         :ok <- same_digest(expected, actual),
         :ok <- rename(tmp, dest) do
      {:ok, dest}
    else
      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:archive_unwritable, reason}}
    end
  end

  # One pass over `input`: every chunk is hashed and written to `tmp`, so the digest returned is
  # of exactly the bytes in `tmp`. The output is closed, and so flushed, before it is trusted.
  defp copy_hashing(input, tmp) do
    case File.open(tmp, [:write, :binary]) do
      {:ok, output} ->
        copied = pump(input, output, :crypto.hash_init(:sha256))

        case {copied, File.close(output)} do
          {{:ok, _digest}, {:error, reason}} -> {:error, {:archive_unwritable, reason}}
          {outcome, _closed} -> outcome
        end

      {:error, reason} ->
        {:error, {:archive_unwritable, reason}}
    end
  end

  defp pump(input, output, hash) do
    case :file.read(input, @chunk_bytes) do
      :eof ->
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, {:recorded_unreadable, reason}}

      {:ok, data} ->
        case :file.write(output, data) do
          :ok -> pump(input, output, :crypto.hash_update(hash, data))
          {:error, reason} -> {:error, {:archive_unwritable, reason}}
        end
    end
  end

  defp same_digest(digest, digest), do: :ok
  defp same_digest(expected, actual), do: {:error, {:sha_mismatch, expected, actual}}

  defp rename(tmp, dest) do
    case File.rename(tmp, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:archive_unwritable, reason}}
    end
  end

  defp explain(:recorded_missing), do: "the recorded file does not exist"

  defp explain({:recorded_unreadable, reason}),
    do: "the recorded file cannot be read (#{inspect(reason)})"

  defp explain({:sha_mismatch, expected, actual}),
    do:
      "the file hashes to #{actual} but the phase recorded #{expected}; " <>
        "only bytes that match the recorded digest are kept"

  defp explain({:archive_unwritable, reason}),
    do: "the archive copy cannot be written (#{inspect(reason)})"
end
