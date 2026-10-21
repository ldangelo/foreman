defmodule ForemanServerWeb.ProjectMemoryController do
  @moduledoc """
  Operator view/edit/delete of a project's memory.

  * `GET    /api/projects/:id/memory`        - index text plus topic entries
  * `GET    /api/projects/:id/memory/:name`  - one topic with content
  * `PUT    /api/projects/:id/memory/:name`  - body `{"description", "content"}`
  * `DELETE /api/projects/:id/memory/:name`
  * `POST   /api/projects/:id/memory/sync`   - record hand edits (drift) in the audit trail

  Everything goes through `ForemanServer.ProjectMemory` with an operator
  author (`x-foreman-operator` header, default `"api"`; the API has a single
  bearer token, so there is no per-operator principal). The write path is
  deliberately NOT routed through `POST /api/commands`: `project.memory.*`
  commands are system-dispatched only.

  Errors are `{"error": "<code>", "message": "..."}` where `code` is the
  `ForemanServer.ProjectMemory.Error` code (or `invalid_body`).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectMemory
  alias ForemanServer.ProjectMemory.{Error, SyncReport, Topic}

  @max_description 200

  def index(conn, %{"id" => project_id}) do
    with {:ok, topics} <- ProjectMemory.list(project_id),
         {:ok, index} <- ProjectMemory.index(project_id) do
      json(conn, %{index: index, entries: Enum.map(topics, &entry/1)})
    else
      {:error, %Error{} = error} -> error_response(conn, error)
    end
  end

  def show(conn, %{"id" => project_id, "name" => name}) do
    case ProjectMemory.read(project_id, name) do
      {:ok, %Topic{} = topic, content} -> json(conn, %{entry: entry(topic), content: content})
      {:error, %Error{} = error} -> error_response(conn, error)
    end
  end

  def update(conn, %{"id" => project_id, "name" => name} = params) do
    with {:ok, attrs} <- validate_body(name, params),
         {:ok, topic} <- ProjectMemory.write(project_id, attrs, author(conn)) do
      json(conn, %{entry: entry(topic)})
    else
      {:error, %Error{} = error} -> error_response(conn, error)
      {:error, :invalid_body, message} -> invalid_body(conn, message)
    end
  end

  def delete(conn, %{"id" => project_id, "name" => name}) do
    case ProjectMemory.forget(project_id, name, author(conn)) do
      {:ok, %Topic{} = topic} -> json(conn, %{entry: entry(topic), status: "forgotten"})
      {:error, %Error{} = error} -> error_response(conn, error)
    end
  end

  def sync(conn, %{"id" => project_id}) do
    case ProjectMemory.sync(project_id, author(conn)) do
      {:ok, %SyncReport{} = report} ->
        json(conn, %{
          recorded: report.recorded,
          forgotten: report.forgotten,
          failed:
            Enum.map(report.failed, fn {name, %Error{code: code, message: message}} ->
              %{name: name, error: Atom.to_string(code), message: message}
            end)
        })

      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  defp validate_body(name, params) do
    description = Map.get(params, "description")
    content = Map.get(params, "content")

    cond do
      not is_binary(content) ->
        {:error, :invalid_body, "content must be a string"}

      not (is_nil(description) or is_binary(description)) ->
        {:error, :invalid_body, "description must be a string"}

      is_binary(description) and String.length(description) > @max_description ->
        {:error, :invalid_body, "description must be at most #{@max_description} characters"}

      true ->
        {:ok, %{name: name, description: description, content: content}}
    end
  end

  defp author(conn) do
    ref =
      case get_req_header(conn, "x-foreman-operator") do
        [value | _] when value != "" -> value
        _ -> "api"
      end

    %{kind: :operator, ref: ref}
  end

  defp entry(%Topic{} = topic) do
    %{
      name: topic.name,
      description: topic.description,
      sha256: topic.sha256,
      bytes: topic.bytes,
      redactions: topic.redactions,
      version: topic.version,
      author_kind: topic.author_kind,
      author_ref: topic.author_ref,
      updated_at: topic.updated_at,
      on_disk: topic.on_disk?
    }
  end

  defp invalid_body(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_body", message: message})
  end

  defp error_response(conn, %Error{code: code, message: message}) do
    conn
    |> put_status(status_for(code))
    |> json(%{error: Atom.to_string(code), message: message})
  end

  defp status_for(code)
       when code in [
              :name_invalid,
              :description_invalid,
              :content_too_large,
              :index_full,
              :too_many_topics,
              :content_not_durable
            ],
       do: :unprocessable_entity

  defp status_for(code) when code in [:not_found, :project_not_found], do: :not_found
  defp status_for(code) when code in [:project_archived, :project_path_unknown], do: :conflict
  defp status_for(_code), do: :internal_server_error
end
