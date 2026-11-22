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

  The file is data, not an error, when it is gone or unreadable (the run's worktree may have
  been cleaned): `state` is `"missing"` or `"unreadable"`, `content` is `null` and `error` says
  why. A broken projection (a phase missing an identifying field, or an artifact without a
  string path) raises instead of turning into a quiet `artifact_not_found`.
  """

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
    @moduledoc "One phase artifact with the state of its file and, when readable, its content."

    @enforce_keys [
      :run_id,
      :phase_id,
      :index,
      :name,
      :path,
      :sha256,
      :bytes,
      :state,
      :content,
      :content_bytes,
      :truncated,
      :sha_matches,
      :error
    ]
    @type state :: String.t()
    @type t :: %__MODULE__{
            run_id: String.t(),
            phase_id: String.t(),
            index: integer(),
            name: String.t(),
            path: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer(),
            state: state(),
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
      :content,
      :content_bytes,
      :truncated,
      :sha_matches,
      :error
    ]
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

  `{:error, :phase_not_found}`: the run has no such phase. `{:error, :artifact_not_found}`: the
  phase recorded no artifact.
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
      content: nil,
      content_bytes: 0,
      truncated: false,
      sha_matches: nil,
      error: nil
    }

    case read_capped(artifact.path) do
      {:ok, head, total_bytes, digest} ->
        {text, truncated?} = to_content(head, total_bytes)

        %Content{
          base
          | content: text,
            content_bytes: byte_size(text),
            truncated: truncated?,
            sha_matches: digest == String.downcase(base.sha256)
        }

      {:error, :enoent} ->
        %Content{base | state: "missing", error: "no such file: the artifact is gone"}

      {:error, reason} ->
        %Content{base | state: "unreadable", error: reason_string(reason)}
    end
  end

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
end
