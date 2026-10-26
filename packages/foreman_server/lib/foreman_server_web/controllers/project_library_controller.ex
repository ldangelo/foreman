defmodule ForemanServerWeb.ProjectLibraryController do
  @moduledoc """
  Operator add/list/read/replace/remove of a project's library
  (`ForemanServer.Library`).

  * `GET    /api/projects/:id/library`                    - entries, markdown index and the limits
  * `GET    /api/projects/:id/library/:entry_id/files/*path` - raw bytes of one file (1 MiB cap)
  * `POST   /api/projects/:id/library`                    - add
  * `PUT    /api/projects/:id/library/:entry_id`          - replace the files of an entry
  * `DELETE /api/projects/:id/library/:entry_id`

  Upload body (add and replace), either:

    * `multipart/form-data` with repeated `files[]` parts whose filename is the
      entry-relative path, optional `name` and `kind` (`file`, default, or `folder`:
      folder rules - hidden files, `node_modules`, size and count budgets - then
      apply server-side to the uploaded tree), or
    * JSON `{"server_path": "/abs/dir", "name": "..."}` to add a directory that lives
      on the server host. Disabled unless `config :foreman_server, :library,
      allow_server_paths: true`, because it lets the caller read arbitrary server
      directories.

  Every response that changes the library includes the `skipped` list (path +
  reason) so a client can show what was left out. The write path is deliberately NOT
  routed through `POST /api/commands`: `project.library.*` commands are
  system-dispatched only. Errors are `{"error": "<code>", "message": "..."}` with
  the `ForemanServer.Library.Error` code (or `invalid_body`).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Library
  alias ForemanServer.Library.{Entry, Error, Ingest, Plan}

  def index(conn, %{"id" => project_id}) do
    with {:ok, entries} <- Library.list(project_id),
         {:ok, index} <- Library.index(project_id) do
      json(conn, %{entries: Enum.map(entries, &entry/1), index: index, limits: limits()})
    else
      {:error, %Error{} = error} -> error_response(conn, error)
    end
  end

  def show(conn, %{"id" => project_id, "entry_id" => entry_id, "path" => path}) do
    case Library.read(project_id, entry_id, Enum.join(path, "/")) do
      {:ok, bytes} ->
        # Library files are untrusted content: never render them in a browser.
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", "attachment")
        |> send_resp(200, bytes)

      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  def create(conn, %{"id" => project_id} = params) do
    with {:ok, source, opts} <- source(params),
         {:ok, result} <- Library.add(project_id, source, opts, author()) do
      conn |> put_status(:created) |> json(result_body(result))
    else
      {:error, %Error{} = error} -> error_response(conn, error)
      {:error, :invalid_body, message} -> invalid_body(conn, message)
    end
  end

  def update(conn, %{"id" => project_id, "entry_id" => entry_id} = params) do
    with {:ok, source, opts} <- source(params),
         {:ok, result} <- Library.replace(project_id, entry_id, source, opts, author()) do
      json(conn, result_body(result))
    else
      {:error, %Error{} = error} -> error_response(conn, error)
      {:error, :invalid_body, message} -> invalid_body(conn, message)
    end
  end

  def delete(conn, %{"id" => project_id, "entry_id" => entry_id}) do
    case Library.remove(project_id, entry_id, author()) do
      {:ok, %Entry{} = entry} -> json(conn, %{entry: entry(entry), status: "removed"})
      {:error, %Error{} = error} -> error_response(conn, error)
    end
  end

  # -- request -> ingest source ------------------------------------------

  defp source(%{"server_path" => path} = params) when is_binary(path) do
    if Application.get_env(:foreman_server, :library, [])[:allow_server_paths] == true do
      {:ok, {:folder, path},
       %{
         name: optional_name(params),
         source: %{"kind" => "server_path", "path_label" => Path.basename(path)}
       }}
    else
      {:error,
       Error.new(
         :server_path_disabled,
         "adding a server-local directory is disabled (config :library, allow_server_paths)"
       )}
    end
  end

  defp source(%{"files" => files} = params) when is_list(files) and files != [] do
    with {:ok, sources} <- uploads(files),
         {:ok, kind} <- kind(params) do
      {:ok, {kind, sources}, %{name: optional_name(params), source: %{"kind" => "upload"}}}
    end
  end

  defp source(_params),
    do:
      {:error, :invalid_body,
       "send multipart files[] parts (filename = relative path) or a JSON server_path"}

  defp uploads(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %Plug.Upload{path: temp, filename: name}, {:ok, acc} when is_binary(name) and name != "" ->
        {:cont, {:ok, [%{relative_path: name, source_path: temp} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid_body, "every files[] part needs a file with a filename"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp kind(%{"kind" => "folder"}), do: {:ok, :folder_files}
  defp kind(%{"kind" => kind}) when kind in ["file", nil], do: {:ok, :files}

  defp kind(%{"kind" => other}),
    do: {:error, :invalid_body, "kind must be file or folder, got #{inspect(other)}"}

  defp kind(_params), do: {:ok, :files}

  defp optional_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp optional_name(_params), do: nil

  # The API has one shared bearer token, so no caller has a verified identity. The audit
  # events are append-only: a header the caller can set to anything (`x-foreman-operator`) is
  # never the author, so every API write is attributed to `api`.
  defp author, do: %{kind: :operator, ref: "api"}

  # -- response ----------------------------------------------------------

  defp limits do
    limits = Ingest.limits()

    %{
      max_files_per_add: limits.max_files_per_add,
      max_file_bytes: limits.max_file_bytes,
      folder_max_files: limits.folder_max_files,
      folder_max_bytes: limits.folder_max_bytes,
      folder_skip_file_bytes: limits.folder_skip_file_bytes,
      upload_max_bytes: limits.upload_max_bytes,
      max_folders: ForemanServer.Aggregates.ProjectLibrary.max_folders(),
      read_max_bytes: Library.read_max_bytes()
    }
  end

  defp result_body(%{entry: %Entry{} = entry, skipped: skipped}),
    do: %{entry: entry(entry), skipped: Enum.map(skipped, &skipped/1)}

  defp skipped(%Plan.Skip{path: path, reason: reason}),
    do: %{path: path, reason: Atom.to_string(reason)}

  defp entry(%Entry{} = e) do
    %{
      entry_id: e.entry_id,
      name: e.name,
      kind: Atom.to_string(e.kind),
      source: e.source,
      file_count: e.file_count,
      bytes: e.bytes,
      manifest_sha256: e.manifest_sha256,
      created_at: e.created_at,
      replaced_at: e.replaced_at,
      files: Enum.map(e.files, &%{path: &1.path, bytes: &1.bytes, sha256: &1.sha256}),
      skipped: e.skipped
    }
  end

  defp invalid_body(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_body", message: message})
  end

  defp error_response(conn, %Error{code: code, message: message, details: details}) do
    conn
    |> put_status(status_for(code))
    |> json(%{error: Atom.to_string(code), message: message, details: safe_details(details)})
  end

  # Details are small typed maps (paths, counts, limits); inspect anything else.
  defp safe_details(details), do: Map.new(details, fn {k, v} -> {k, json_safe(v)} end)

  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp json_safe(%{} = v) when not is_struct(v), do: safe_details(v)
  defp json_safe(v), do: inspect(v)

  defp status_for(code)
       when code in [
              :name_invalid,
              :path_invalid,
              :too_many_files,
              :file_too_large,
              :folder_empty,
              :too_many_folders,
              :duplicate_name,
              :source_missing
            ],
       do: :unprocessable_entity

  defp status_for(:too_large), do: :payload_too_large

  defp status_for(code) when code in [:not_found, :project_not_found], do: :not_found
  defp status_for(:server_path_disabled), do: :forbidden
  defp status_for(code) when code in [:project_archived, :project_path_unknown], do: :conflict
  defp status_for(_code), do: :internal_server_error
end
