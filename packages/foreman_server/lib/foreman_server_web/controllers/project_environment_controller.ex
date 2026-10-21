defmodule ForemanServerWeb.ProjectEnvironmentController do
  @moduledoc """
  Operator surface for a project's environment (E4-S6).

    * `GET /api/projects/:id/environment` - `ForemanServer.ProjectEnvironmentDTO`
    * `PUT /api/projects/:id/environment` - body `{vars?, setup_script?, network?}`,
      dispatched as the operator command `project.environment.set`
    * `PUT /api/projects/:id/secrets/:name` - body `{"value": "..."}`; the value
      goes straight to `ForemanServer.SecretStore`, the response is `{name, version}`
    * `DELETE /api/projects/:id/secrets/:name`

  No response, log line or error ever contains a secret value: `value` is in
  `config :phoenix, :filter_parameters` and errors carry names and codes only.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{CommandGateway, ProjectEnvironmentDTO, ProjectSecrets}
  alias ForemanServer.SecretStore.Error, as: SecretError

  @env_keys ~w(vars setup_script network)

  def show(conn, %{"id" => project_id}) do
    case ProjectEnvironmentDTO.fetch(project_id) do
      {:ok, dto} -> conn |> put_status(:ok) |> json(dto)
      :not_found -> not_found(conn)
    end
  end

  def update(conn, %{"id" => project_id} = params) do
    payload = params |> Map.take(@env_keys) |> Map.put("project_id", project_id)

    command = %{
      type: "project.environment.set",
      command_id:
        "project.environment.set:" <> project_id <> ":" <> Elixir.EventStore.UUID.uuid4(),
      aggregate_id: "project:" <> project_id,
      payload: payload
    }

    case CommandGateway.dispatch_operator(command) do
      {:ok, _} ->
        {:ok, dto} = ProjectEnvironmentDTO.fetch(project_id)
        conn |> put_status(:ok) |> json(dto)

      {:error, {:not_found, :project, _}} ->
        not_found(conn)

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def put_secret(conn, %{"id" => project_id, "name" => name, "value" => value})
      when is_binary(value) do
    case ProjectSecrets.set(project_id, name, value, "http") do
      {:ok, result} -> conn |> put_status(:ok) |> json(result)
      {:error, reason} -> secret_error(conn, reason)
    end
  end

  def put_secret(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_secret_value", message: "body must be {\"value\": \"<string>\"}"})
  end

  def delete_secret(conn, %{"id" => project_id, "name" => name}) do
    case ProjectSecrets.unset(project_id, name, "http") do
      {:ok, result} -> conn |> put_status(:ok) |> json(result)
      {:error, reason} -> secret_error(conn, reason)
    end
  end

  defp secret_error(conn, {:not_found, :project, _}), do: not_found(conn)

  defp secret_error(conn, %SecretError{code: :secret_not_found} = error),
    do:
      conn
      |> put_status(:not_found)
      |> json(%{error: "secret_not_found", name: error.details[:name]})

  defp secret_error(conn, %SecretError{code: code} = error)
       when code in [:invalid_secret_name, :invalid_secret_value, :invalid_project_id],
       do:
         conn
         |> put_status(:unprocessable_entity)
         |> json(%{error: Atom.to_string(code), message: error.message})

  defp secret_error(conn, %SecretError{code: code}),
    do: conn |> put_status(:internal_server_error) |> json(%{error: Atom.to_string(code)})

  defp secret_error(conn, reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

  defp not_found(conn),
    do:
      conn |> put_status(:not_found) |> json(%{error: "not_found", reason: ":project_not_found"})
end
