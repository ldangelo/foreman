defmodule ForemanServer.ProjectMemory.Store do
  @moduledoc """
  Filesystem layer of project memory. No CQRS knowledge: pure functions over a
  project path.

  Layout under `<project_path>/.foreman/memory/`:

    * `MEMORY.md` - generated index, one `- [name](name.md) - description`
      line per topic, sorted by name. Only this module writes it.
    * `<name>.md` - one topic file. An optional first line
      `<!-- description: ... -->` carries the one-line description (the hook
      shown in the index); the rest is the content. A hand-created file
      without the header has an empty description.

  `write/3` order: validate name -> redact (log-policy patterns plus the
  project's secret values) -> durability guard -> size caps -> index cap ->
  `.gitignore` entry -> atomic topic write (mode 0600, temp file + rename) ->
  atomic index regeneration. Every rejection happens before the topic file is
  touched, so a rejected write leaves the directory byte-identical.

  Durability guard (`:content_not_durable`, content of at least
  `:min_guard_bytes` only): `reason: :repeated_lines` when more than
  `:max_repeat_ratio` of the non-empty lines are identical, and
  `reason: :mostly_secrets` when more than `:max_redaction_ratio` of the
  original bytes were replaced by redaction.

  Caps and thresholds come from `config :foreman_server, :project_memory`.
  """

  alias ForemanServer.ForemanDir
  alias ForemanServer.Identity
  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectMemory.Error

  @index_file "MEMORY.md"
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @reserved_names ["memory"]
  @marker "[REDACTED]"
  @min_repeat_lines 4
  @header_pattern ~r/\A<!-- description: (.*?) -->\n/

  @defaults [
    max_topic_bytes: 65_536,
    max_index_lines: 200,
    max_index_bytes: 25_600,
    max_topics: 200,
    max_description_chars: 200,
    max_repeat_ratio: 0.5,
    max_redaction_ratio: 0.5,
    min_guard_bytes: 200
  ]

  defmodule Entry do
    @moduledoc "Metadata of one stored topic (never the content)."
    @enforce_keys [:name, :sha256, :bytes]
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer(),
            redactions: non_neg_integer()
          }
    defstruct [:name, :sha256, :bytes, description: "", redactions: 0]
  end

  @type attrs :: %{name: String.t(), description: String.t() | nil, content: String.t()}

  @doc "Absolute memory directory of a project path."
  @spec memory_dir(String.t()) :: String.t()
  def memory_dir(project_path), do: Path.join([project_path, ".foreman", "memory"])

  @doc "Validate a topic name."
  @spec validate_name(term()) :: :ok | {:error, Error.t()}
  def validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name) and name not in @reserved_names,
      do: :ok,
      else: {:error, Error.new(:name_invalid, "invalid memory topic name", %{name: name})}
  end

  def validate_name(name),
    do: {:error, Error.new(:name_invalid, "invalid memory topic name", %{name: inspect(name)})}

  @doc "Redact, validate, cap and atomically store one topic."
  @spec write(String.t(), [String.t()], attrs()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def write(project_path, project_secrets, %{name: name, content: content} = attrs)
      when is_binary(project_path) and is_list(project_secrets) and is_binary(content) do
    with :ok <- validate_name(name),
         {:ok, description} <- normalise_description(Map.get(attrs, :description)),
         {body, body_redactions} = redact(content, project_secrets),
         {description, desc_redactions} = redact_description(description, project_secrets),
         :ok <- check_size(body),
         :ok <- durability_guard(content, body, body_redactions),
         {:ok, entries} <- list_entries(project_path),
         :ok <- check_topic_count(entries, name),
         file = encode_file(description, body),
         entry = build_entry(name, description, file, body_redactions + desc_redactions),
         {:ok, index} <- render_index(replace_entry(entries, entry)),
         :ok <- ignore_memory(project_path),
         :ok <- put(project_path, topic_file(name), file),
         :ok <- put(project_path, @index_file, index) do
      {:ok, entry}
    end
  end

  @doc "Remove one topic and regenerate the index."
  @spec forget(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def forget(project_path, name) when is_binary(project_path) do
    with :ok <- validate_name(name),
         {:ok, entry, _content} <- read(project_path, name),
         :ok <- remove(project_path, topic_file(name)),
         {:ok, entries} <- list_entries(project_path),
         :ok <- put(project_path, @index_file, render_index!(entries)) do
      {:ok, entry}
    end
  end

  @doc "Read one topic: its metadata and content (header stripped)."
  @spec read(String.t(), String.t()) :: {:ok, Entry.t(), String.t()} | {:error, Error.t()}
  def read(project_path, name) when is_binary(project_path) do
    with :ok <- validate_name(name),
         {:ok, raw} <- read_raw(project_path, name) do
      {entry, content} = decode_file(name, raw)
      {:ok, entry, content}
    end
  end

  @doc "Raw on-disk bytes of one topic file."
  @spec read_raw(String.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_raw(project_path, name) do
    case File.read(Path.join(memory_dir(project_path), topic_file(name))) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "memory topic not found", %{name: name})}

      {:error, reason} ->
        {:error, write_error(name, reason)}
    end
  end

  @doc "Every topic's metadata, sorted by name. A missing directory is an empty list."
  @spec list(String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(project_path) when is_binary(project_path), do: list_entries(project_path)

  @doc "The generated `MEMORY.md` text (empty string when there is no memory)."
  @spec index(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def index(project_path) when is_binary(project_path) do
    case File.read(Path.join(memory_dir(project_path), @index_file)) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, write_error(@index_file, reason)}
    end
  end

  @doc """
  Restore a topic to previously captured raw bytes (`nil` removes it) and
  regenerate the index. Used by the facade to roll disk back.
  """
  @spec restore(String.t(), String.t(), binary() | nil) :: :ok | {:error, Error.t()}
  def restore(project_path, name, previous) do
    with :ok <- validate_name(name),
         :ok <- restore_file(project_path, name, previous),
         {:ok, entries} <- list_entries(project_path) do
      put(project_path, @index_file, render_index!(entries))
    end
  end

  @doc "Rewrite `MEMORY.md` from the topic files on disk."
  @spec regenerate_index(String.t()) :: :ok | {:error, Error.t()}
  def regenerate_index(project_path) do
    with {:ok, entries} <- list_entries(project_path) do
      put(project_path, @index_file, render_index!(entries))
    end
  end

  @doc "Redact text with the log policy plus the project's secret values; returns `{text, count}`."
  @spec redact(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def redact(text, secrets) when is_binary(text) do
    redacted = WorkerLogPolicy.redact(text, secrets)
    {redacted, max(count_markers(redacted) - count_markers(text), 0)}
  end

  @doc "Configured value (`config :foreman_server, :project_memory`)."
  @spec config(atom()) :: term()
  def config(key) do
    :foreman_server
    |> Application.get_env(:project_memory, [])
    |> Keyword.get_lazy(key, fn -> Keyword.fetch!(@defaults, key) end)
  end

  # --- internals -------------------------------------------------------

  defp topic_file(name), do: name <> ".md"

  defp normalise_description(nil), do: {:ok, ""}

  defp normalise_description(text) when is_binary(text) do
    one_line =
      text |> String.replace(~r/\s+/, " ") |> String.replace("-->", "--\u200B>") |> String.trim()

    {:ok, String.slice(one_line, 0, config(:max_description_chars))}
  end

  defp normalise_description(other),
    do:
      {:error,
       Error.new(:description_invalid, "description must be a string", %{got: inspect(other)})}

  defp redact_description("", _secrets), do: {"", 0}
  defp redact_description(text, secrets), do: redact(text, secrets)

  defp count_markers(text), do: text |> String.split(@marker) |> length() |> Kernel.-(1)

  defp durability_guard(original, redacted, redactions) do
    cond do
      byte_size(original) < config(:min_guard_bytes) ->
        :ok

      repeated_ratio(original) > config(:max_repeat_ratio) ->
        not_durable(:repeated_lines)

      replaced_ratio(original, redacted, redactions) > config(:max_redaction_ratio) ->
        not_durable(:mostly_secrets)

      true ->
        :ok
    end
  end

  defp not_durable(reason),
    do:
      {:error,
       Error.new(:content_not_durable, "content looks like a dump, not a durable fact", %{
         reason: reason
       })}

  defp repeated_ratio(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case lines do
      lines when length(lines) < @min_repeat_lines ->
        0.0

      _ ->
        max = lines |> Enum.frequencies() |> Map.values() |> Enum.max()
        max / length(lines)
    end
  end

  # Fraction of the original bytes that redaction replaced: the redacted text
  # minus its markers is exactly the original bytes that were kept.
  defp replaced_ratio(original, redacted, redactions) do
    kept = byte_size(redacted) - redactions * byte_size(@marker)
    max(byte_size(original) - kept, 0) / byte_size(original)
  end

  defp check_size(body) do
    max = config(:max_topic_bytes)

    if byte_size(body) > max,
      do:
        {:error,
         Error.new(:content_too_large, "memory topic exceeds size cap", %{
           bytes: byte_size(body),
           max: max
         })},
      else: :ok
  end

  defp check_topic_count(entries, name) do
    max = config(:max_topics)

    if length(entries) >= max and not Enum.any?(entries, &(&1.name == name)),
      do:
        {:error, Error.new(:too_many_topics, "project memory topic limit reached", %{max: max})},
      else: :ok
  end

  defp encode_file("", body), do: body
  defp encode_file(description, body), do: "<!-- description: " <> description <> " -->\n" <> body

  defp decode_file(name, raw) do
    {description, content} =
      case Regex.run(@header_pattern, raw) do
        [header, description] ->
          {description, binary_part(raw, byte_size(header), byte_size(raw) - byte_size(header))}

        nil ->
          {"", raw}
      end

    {build_entry(name, description, raw, 0), content}
  end

  defp build_entry(name, description, file, redactions),
    do: %Entry{
      name: name,
      description: description,
      sha256: Identity.sha256(file),
      bytes: byte_size(file),
      redactions: redactions
    }

  defp replace_entry(entries, %Entry{name: name} = entry),
    do: Enum.sort_by([entry | Enum.reject(entries, &(&1.name == name))], & &1.name)

  defp list_entries(project_path) do
    dir = memory_dir(project_path)

    case File.ls(dir) do
      {:ok, files} ->
        entries =
          files
          |> Enum.flat_map(&topic_name/1)
          |> Enum.sort()
          |> Enum.flat_map(fn name ->
            case read_raw(project_path, name) do
              {:ok, raw} -> [raw |> then(&decode_file(name, &1)) |> elem(0)]
              {:error, _} -> []
            end
          end)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, write_error(@index_file, reason)}
    end
  end

  defp topic_name(file) do
    with true <- String.ends_with?(file, ".md"),
         name = String.replace_suffix(file, ".md", ""),
         :ok <- validate_name(name) do
      [name]
    else
      _ -> []
    end
  end

  defp render_index(entries) do
    text = Enum.map_join(entries, "", &index_line/1)
    lines = length(entries)

    if lines > config(:max_index_lines) or byte_size(text) > config(:max_index_bytes),
      do:
        {:error,
         Error.new(:index_full, "MEMORY.md index would exceed its cap", %{
           lines: lines,
           bytes: byte_size(text)
         })},
      else: {:ok, text}
  end

  # Shrinking operations (forget/restore) must succeed even when hand edits
  # pushed the index over its cap, so they skip the cap.
  defp render_index!(entries), do: Enum.map_join(entries, "", &index_line/1)

  defp index_line(%Entry{name: name, description: ""}), do: "- [#{name}](#{name}.md)\n"
  defp index_line(%Entry{name: name, description: d}), do: "- [#{name}](#{name}.md) - #{d}\n"

  defp ignore_memory(project_path) do
    case ForemanDir.ensure_ignored(project_path, "memory/") do
      :ok ->
        :ok

      {:error, %ForemanDir.Error{} = e} ->
        {:error, Error.new(:write_failed, e.message, e.details)}
    end
  end

  defp restore_file(project_path, name, nil),
    do: remove_if_present(project_path, topic_file(name))

  defp restore_file(project_path, name, raw) when is_binary(raw),
    do: put(project_path, topic_file(name), raw)

  defp remove_if_present(project_path, file) do
    case File.rm(Path.join(memory_dir(project_path), file)) do
      ret when ret in [:ok, {:error, :enoent}] -> :ok
      {:error, reason} -> {:error, write_error(file, reason)}
    end
  end

  defp remove(project_path, file) do
    case File.rm(Path.join(memory_dir(project_path), file)) do
      :ok -> :ok
      {:error, reason} -> {:error, write_error(file, reason)}
    end
  end

  defp put(project_path, file, contents) do
    dir = memory_dir(project_path)
    path = Path.join(dir, file)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, write_error(file, reason)}
    end
  end

  defp write_error(file, reason),
    do:
      Error.new(:write_failed, "memory filesystem operation failed", %{
        file: file,
        reason: inspect(reason)
      })
end
