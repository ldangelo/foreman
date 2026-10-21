defmodule ForemanServer.ForemanDir do
  @moduledoc """
  Helpers for a repository's `.foreman/` directory.

  `ensure_ignored/2` idempotently appends one directory entry to
  `<repo>/.foreman/.gitignore`. It never reorders or rewrites existing lines.

  Only *library* paths that hold generated or private content may be passed
  here (for example `"memory/"`). `.foreman/Dockerfile`, `.foreman/bead.exs`
  and `.foreman/pi-models.json` are tracked project configuration and MUST
  never be ignored by this helper.
  """

  defmodule Error do
    @moduledoc "Typed failure of a `.foreman/` directory operation."
    @enforce_keys [:code, :message]
    @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
    defstruct [:code, :message, details: %{}]
  end

  @doc """
  Ensure `.foreman/.gitignore` under `repo_path` contains `entry` as a
  directory line (a single trailing slash is enforced). A second call is a
  no-op; pre-existing lines are preserved byte-for-byte.
  """
  @spec ensure_ignored(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def ensure_ignored(repo_path, entry) when is_binary(repo_path) and is_binary(entry) do
    line = normalise(entry)
    path = Path.join([repo_path, ".foreman", ".gitignore"])

    with :ok <- check_entry(line, entry),
         :ok <- mkdir(path),
         {:ok, existing} <- read_existing(path) do
      if ignored_line?(existing, line), do: :ok, else: append(path, existing, line)
    end
  end

  defp normalise(entry), do: entry |> String.trim() |> String.trim_trailing("/") |> Kernel.<>("/")

  defp check_entry("/", entry),
    do: {:error, error("empty .gitignore entry", %{entry: entry})}

  defp check_entry(_line, _entry), do: :ok

  defp ignored_line?(existing, line) do
    existing
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.member?(line)
  end

  defp mkdir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, error("cannot create .foreman", %{reason: inspect(reason)})}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, error("cannot read .gitignore", %{reason: inspect(reason)})}
    end
  end

  # Append mode: a concurrent caller can at worst duplicate the line, never
  # drop one.
  defp append(path, existing, line) do
    prefix = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"

    case File.open(path, [:append, :binary], &IO.binwrite(&1, prefix <> line <> "\n")) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, error("cannot append .gitignore", %{reason: inspect(reason)})}

      {:error, reason} ->
        {:error, error("cannot append .gitignore", %{reason: inspect(reason)})}
    end
  end

  defp error(message, details),
    do: %Error{code: :gitignore_write_failed, message: message, details: details}
end
