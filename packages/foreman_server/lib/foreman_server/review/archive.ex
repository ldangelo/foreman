defmodule ForemanServer.Review.Archive do
  @moduledoc """
  On-disk session archive, one directory per run or jobsite:

      <archive_root>/<kind>/<subject_id>/
        manifest.json  request.md  transcript.jsonl  diff.patch
        changed-files.txt  analysis.json  analysis.md
        diffs/<repo_id>.patch  diffs/<repo_id>.files.txt   (non-primary repos of a multi-repo run)

  `archive_root` defaults to `<repo_path>/.foreman/sessions`; a configured
  `config :foreman_server, :review, archive_root:` is used verbatim.

  Every write failure is returned as `{:error, %Review.Error{code:
  :archive_write_failed}}`, logged at `:warning`, and — when the manifest is
  itself readable — recorded in the manifest's `capture_errors`, so a failed
  capture never looks like a clean empty archive.
  """

  require Logger

  alias ForemanServer.Review.Error

  @manifest_schema "foreman.review.manifest.v1"
  @manifest_file "manifest.json"
  @transcript_file "transcript.jsonl"
  @default_max_transcript_bytes 2_000_000

  @manifest_defaults %{
    "schema" => @manifest_schema,
    "kind" => nil,
    "subject_id" => nil,
    "project_id" => nil,
    "repo_path" => nil,
    "bead_id" => nil,
    "request" => %{"source" => nil, "title" => nil, "prompt" => nil, "workflow_name" => nil},
    "agent" => %{"provider" => nil, "model" => nil},
    "provider_session_ids" => [],
    "strategy" => nil,
    "branch" => nil,
    "base_ref" => nil,
    "worktree_path" => nil,
    "status" => nil,
    "started_at" => nil,
    "finished_at" => nil,
    "transcript_source" => nil,
    "transcript_truncated" => false,
    "diff_status" => "unavailable",
    "capture_errors" => []
  }

  @spec dir(:run | :jobsite, String.t(), String.t()) :: String.t()
  def dir(kind, subject_id, repo_path)
      when kind in [:run, :jobsite] and is_binary(subject_id) and is_binary(repo_path) do
    root =
      case config(:archive_root, nil) do
        nil -> Path.join([repo_path, ".foreman", "sessions"])
        configured when is_binary(configured) -> configured
      end

    Path.join([root, Atom.to_string(kind), subject_id])
  end

  @doc "Create the archive directory and write the initial manifest (defaults fill absent keys with explicit nulls)."
  @spec init(String.t(), map()) :: :ok | {:error, Error.t()}
  def init(dir, manifest) when is_binary(dir) and is_map(manifest) do
    with :ok <- mkdir(dir) do
      put_manifest(dir, Map.merge(@manifest_defaults, stringify(manifest)))
    end
  end

  @doc "Replace the manifest atomically."
  @spec put_manifest(String.t(), map()) :: :ok | {:error, Error.t()}
  def put_manifest(dir, manifest) when is_binary(dir) and is_map(manifest) do
    path = Path.join(dir, @manifest_file)

    case atomic_write_json(path, manifest) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        Logger.warning("review archive: manifest write failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc "Shallow-merge `updates` into the existing manifest."
  @spec merge_manifest(String.t(), map()) :: :ok | {:error, Error.t()}
  def merge_manifest(dir, updates) when is_binary(dir) and is_map(updates) do
    with {:ok, manifest} <- read_manifest(dir) do
      put_manifest(dir, Map.merge(manifest, stringify(updates)))
    end
  end

  @spec read_manifest(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def read_manifest(dir) when is_binary(dir) do
    path = Path.join(dir, @manifest_file)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = manifest} ->
            {:ok, manifest}

          {:ok, other} ->
            {:error,
             Error.new(:archive_malformed, "manifest is not a JSON object", %{
               path: path,
               got: inspect(other)
             })}

          {:error, reason} ->
            {:error,
             Error.new(:archive_malformed, "manifest is not valid JSON", %{
               path: path,
               reason: inspect(reason)
             })}
        end

      {:error, reason} ->
        {:error,
         Error.new(:archive_missing, "manifest not readable", %{
           path: path,
           reason: inspect(reason)
         })}
    end
  end

  @doc "Atomically write `dir/name`. `name` must be a bare file name."
  @spec write_file(String.t(), String.t(), iodata()) :: :ok | {:error, Error.t()}
  def write_file(dir, name, contents) when is_binary(dir) and is_binary(name) do
    path = Path.join(dir, name)

    result =
      if Path.basename(name) == name and name not in ["", ".", ".."] do
        atomic_write(path, contents)
      else
        {:error,
         Error.new(:archive_write_failed, "archive file name must be a bare name", %{name: name})}
      end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> fail(dir, "write_file:" <> name, error)
    end
  end

  @doc """
  Atomically write `dir/diffs/<repo_id>.<ext>` (`ext` is `"patch"` or
  `"files.txt"`), the per-repository diff files of a multi-repo archive.
  `repo_id` must be a valid repository id, so it can never traverse out of
  `diffs/`.
  """
  @spec write_repo_file(String.t(), String.t(), String.t(), iodata()) ::
          :ok | {:error, Error.t()}
  def write_repo_file(dir, repo_id, ext, contents)
      when is_binary(dir) and is_binary(repo_id) and ext in ["patch", "files.txt"] do
    name = "diffs/" <> repo_id <> "." <> ext

    result =
      case ForemanServer.Projects.RepoValidation.validate_id(repo_id) do
        :ok ->
          atomic_write(Path.join(dir, name), contents)

        {:error, _} ->
          {:error,
           Error.new(:archive_write_failed, "archive repo id is not a valid id", %{
             repo_id: repo_id
           })}
      end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> fail(dir, "write_file:" <> name, error)
    end
  end

  @doc """
  Append harness events to `transcript.jsonl`, one JSON object per event.
  Stops at `:max_transcript_bytes` and records `transcript_truncated: true`.
  """
  @spec append_events(String.t(), [map()]) :: :ok | {:error, Error.t()}
  def append_events(_dir, []), do: :ok

  def append_events(dir, events) when is_binary(dir) and is_list(events) do
    path = Path.join(dir, @transcript_file)
    max = config(:max_transcript_bytes, @default_max_transcript_bytes)

    with :ok <- mkdir(dir),
         {:ok, current} <- current_size(path),
         {lines, truncated?} = take_within(events, current, max),
         :ok <- append_lines(path, lines) do
      if truncated?, do: merge_manifest(dir, %{"transcript_truncated" => true}), else: :ok
    else
      {:error, %Error{} = error} -> fail(dir, "append_events", error)
    end
  end

  @spec capture_enabled?() :: boolean()
  def capture_enabled?, do: config(:capture, false) == true

  @doc """
  Append a `{stage, code, message}` entry to the manifest's `capture_errors`.

  A failed capture must never look like a clean archive, so when the manifest is
  absent or unreadable (capture opened late, or the open itself failed) a minimal
  manifest is created: schema defaults, `kind`/`subject_id` inferred from the
  `<kind>/<subject_id>` directory layout, and this entry. Returns `:ok` only when
  the entry is durable on disk; otherwise a typed error (the reason is also logged).
  """
  @spec record_capture_error(String.t(), String.t(), Error.t()) :: :ok | {:error, Error.t()}
  def record_capture_error(dir, stage, %Error{} = error) do
    entry = %{
      "stage" => stage,
      "code" => Atom.to_string(error.code),
      "message" => error.message
    }

    case read_manifest(dir) do
      {:ok, manifest} ->
        put_manifest(
          dir,
          Map.update(manifest, "capture_errors", [entry], &(List.wrap(&1) ++ [entry]))
        )

      {:error, _unreadable} ->
        init(dir, %{
          "kind" => Path.basename(Path.dirname(dir)),
          "subject_id" => Path.basename(dir),
          "capture_errors" => [entry]
        })
    end
  end

  # ---------------------------------------------------------------------

  defp fail(dir, stage, %Error{} = error) do
    Logger.warning("review archive: #{stage} failed: #{inspect(error)}")
    record_capture_error(dir, stage, error)
    {:error, error}
  end

  defp take_within(events, current, max) do
    secrets = env_secrets()

    {lines, _size, truncated?} =
      Enum.reduce_while(events, {[], current, false}, fn event, {acc, size, _} ->
        line = encode_event(event, secrets)
        bytes = byte_size(line)

        if size + bytes > max,
          do: {:halt, {acc, size, true}},
          else: {:cont, {[line | acc], size + bytes, false}}
      end)

    {Enum.reverse(lines), truncated?}
  end

  @doc """
  One transcript JSONL line (newline-terminated) for a harness event.

  `text` comes from the string key `"text"`, which every adapter sets on
  `:output_text_delta`, `:output_text_final`, `:command_output_delta` and
  `:thinking_delta`. A `:provider_event` that carries a process stream line
  (`%{"stream" => "stderr", "data" => line}`) is kept too, with `stream` set,
  so provider diagnostics are not dropped. Events with neither have
  `text: null`.
  """
  @spec encode_event(map(), [String.t()] | nil) :: binary()
  def encode_event(event, secrets \\ nil) do
    secrets = secrets || env_secrets()

    {text, stream} =
      case Map.get(event, :payload) do
        %{"text" => text} -> {text, nil}
        %{"data" => data, "stream" => stream} when is_binary(data) -> {data, stream}
        _ -> {nil, nil}
      end

    encode_line(
      to_string(Map.get(event, :type)),
      Map.get(event, :timestamp),
      text,
      stream,
      secrets
    )
  end

  @doc """
  One redacted transcript line from already-extracted fields. Text is passed
  through `Jido.Harness.Redaction.redact/2` (sensitive env values and bearer
  tokens) before it can reach disk.
  """
  @spec encode_line(String.t(), term(), term(), String.t() | nil, [String.t()] | nil) ::
          binary()
  def encode_line(type, timestamp, text, stream, secrets \\ nil) do
    secrets = secrets || env_secrets()

    Jason.encode!(%{
      "type" => type,
      "timestamp" => timestamp,
      "text" => Jido.Harness.Redaction.redact(text, secrets),
      "stream" => stream
    }) <> "\n"
  end

  # Computed from the live environment (not Redaction's per-process cache) so a
  # secret set after the process first redacted is still caught.
  defp env_secrets, do: Jido.Harness.Redaction.secrets_from_env(System.get_env())

  defp append_lines(_path, []), do: :ok

  defp append_lines(path, lines) do
    case File.write(path, lines, [:append]) do
      :ok -> :ok
      {:error, reason} -> {:error, write_error(path, reason)}
    end
  end

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> {:error, write_error(path, reason)}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, write_error(dir, reason)}
    end
  end

  defp atomic_write_json(path, map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} ->
        atomic_write(path, json)

      {:error, reason} ->
        {:error, write_error(path, {:encode, reason})}
    end
  end

  defp atomic_write(path, contents) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, write_error(path, reason)}
    end
  end

  defp write_error(path, reason) do
    Error.new(:archive_write_failed, "archive write failed", %{
      path: path,
      reason: inspect(reason)
    })
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp config(key, default) do
    :foreman_server |> Application.get_env(:review, []) |> Keyword.get(key, default)
  end
end
