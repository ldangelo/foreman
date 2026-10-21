defmodule ForemanServer.MCP.LibraryTools do
  @moduledoc """
  Read-only MCP tools over the project library (E5-S6):

    * `foreman_project_library_list` - entries (id, name, kind, counts, files) plus
      the markdown index
    * `foreman_project_library_read` - one file of an entry (at most 1 MiB)

  There is intentionally NO add/remove tool: agents contribute files only through
  `ForemanServer.Library.Collector` (opt-in per project), never by writing to the
  library directly. `ForemanServer.MCP.Tools` advertises `schemas/0` and delegates
  its `tool_foreman_project_library_*` functions here.
  """

  alias ForemanServer.Library
  alias ForemanServer.Library.{Entry, Error}
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.Telemetry

  defmodule FileInfo do
    @moduledoc "One file of a library entry as listed by `foreman_project_library_list`."
    @enforce_keys [:path, :bytes]
    @type t :: %__MODULE__{path: String.t(), bytes: non_neg_integer()}
    @derive Jason.Encoder
    defstruct [:path, :bytes]
  end

  defmodule EntryInfo do
    @moduledoc "Whitelisted library entry metadata returned by the library tools."
    @enforce_keys [:entry_id, :name, :kind]
    @type t :: %__MODULE__{
            entry_id: String.t(),
            name: String.t(),
            kind: String.t(),
            file_count: non_neg_integer(),
            bytes: non_neg_integer(),
            read_path: String.t(),
            files: [FileInfo.t()]
          }
    @derive Jason.Encoder
    defstruct [:entry_id, :name, :kind, :read_path, file_count: 0, bytes: 0, files: []]
  end

  defmodule ListResult do
    @moduledoc "Result of `foreman_project_library_list`."
    @enforce_keys [:project_id, :index, :entries]
    @type t :: %__MODULE__{project_id: String.t(), index: String.t(), entries: [EntryInfo.t()]}
    @derive Jason.Encoder
    defstruct [:project_id, :index, :entries]
  end

  defmodule ReadResult do
    @moduledoc "Result of `foreman_project_library_read`: `content` is UTF-8 text or base64 per `encoding`."
    @enforce_keys [:entry_id, :path, :bytes, :encoding, :content]
    @type t :: %__MODULE__{
            entry_id: String.t(),
            path: String.t(),
            bytes: non_neg_integer(),
            encoding: String.t(),
            content: String.t()
          }
    @derive Jason.Encoder
    defstruct [:entry_id, :path, :bytes, :encoding, :content]
  end

  @list_tool "foreman_project_library_list"
  @read_tool "foreman_project_library_read"

  @doc "Tool schemas, appended to `ForemanServer.MCP.Tools`'s tool list."
  @spec schemas() :: [map()]
  def schemas do
    [
      %{
        name: @list_tool,
        description:
          "List the project's library: files and folders every agent of the project can read " <>
            "(read-only). Read a file with foreman_project_library_read.",
        inputSchema: %{
          type: "object",
          required: ["project_id"],
          properties: %{"project_id" => %{type: "string", description: "The project ID."}}
        }
      },
      %{
        name: @read_tool,
        description:
          "Read one file of a library entry by its entry-relative path (at most 1 MiB; " <>
            "text is returned as UTF-8, other files as base64).",
        inputSchema: %{
          type: "object",
          required: ["project_id", "entry_id", "path"],
          properties: %{
            "project_id" => %{type: "string", description: "The project ID."},
            "entry_id" => %{type: "string", description: "Library entry id from the list."},
            "path" => %{
              type: "string",
              description: "Path inside the entry, e.g. \"docs/spec.md\"."
            }
          }
        }
      }
    ]
  end

  @doc "Runs `foreman_project_library_list`."
  @spec list(map()) :: {:ok, ListResult.t()} | {:error, ToolError.t()}
  def list(%{project_id: project_id}) do
    reply(@list_tool, fn ->
      with {:ok, entries} <- Library.list(project_id),
           {:ok, index} <- Library.index(project_id) do
        {:ok,
         %ListResult{
           project_id: project_id,
           index: index,
           entries: Enum.map(entries, &entry_info/1)
         }}
      end
    end)
  end

  @doc "Runs `foreman_project_library_read`."
  @spec read(map()) :: {:ok, ReadResult.t()} | {:error, ToolError.t()}
  def read(%{project_id: project_id, entry_id: entry_id, path: path}) do
    reply(@read_tool, fn ->
      with {:ok, bytes} <- Library.read(project_id, entry_id, path) do
        {encoding, content} =
          if String.valid?(bytes), do: {"utf8", bytes}, else: {"base64", Base.encode64(bytes)}

        {:ok,
         %ReadResult{
           entry_id: entry_id,
           path: path,
           bytes: byte_size(bytes),
           encoding: encoding,
           content: content
         }}
      end
    end)
  end

  defp entry_info(%Entry{} = e) do
    %EntryInfo{
      entry_id: e.entry_id,
      name: e.name,
      kind: Atom.to_string(e.kind),
      file_count: e.file_count,
      bytes: e.bytes,
      read_path: "$FOREMAN_LIBRARY_PATH/#{e.entry_id}/files/",
      files: Enum.map(e.files, &%FileInfo{path: &1.path, bytes: &1.bytes})
    }
  end

  defp reply(tool, fun) do
    start_us = System.monotonic_time(:microsecond)
    result = fun.()
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, _} = ok ->
        Telemetry.mcp_tool_call(duration_us, tool, :ok)
        ok

      {:error, %Error{} = error} ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        {:error, tool_error(error)}
    end
  end

  defp tool_error(%Error{code: code, message: message})
       when code in [:not_found, :project_not_found],
       do: %ToolError{code: "NOT_FOUND", message: "#{code}: #{message}"}

  defp tool_error(%Error{code: code, message: message})
       when code in [:path_invalid, :too_large, :name_invalid],
       do: %ToolError{code: "INVALID_PARAMS", message: "#{code}: #{message}"}

  defp tool_error(%Error{code: code, message: message}),
    do: %ToolError{code: "DOMAIN_ERROR", message: "#{code}: #{message}"}
end
