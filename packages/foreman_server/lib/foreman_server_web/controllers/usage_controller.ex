defmodule ForemanServerWeb.UsageController do
  @moduledoc """
  `GET /api/projects/:id/usage`: token and cost usage of a project, optionally
  narrowed by `from`/`to` (UTC dates), `group_by` and `limit`. The body is
  `ForemanServer.UsageDTO`; a bad parameter is a 422 with the stable code in
  `error`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{Telemetry, UsageDTO}

  def show(conn, %{"id" => project_id} = params) do
    started_at = System.monotonic_time()

    with {:ok, parsed} <- UsageDTO.parse_params(Map.delete(params, "id")),
         {:ok, dto} <- UsageDTO.build(project_id, parsed, DateTime.utc_now()) do
      telemetry(started_at, project_id, %{outcome: :ok})
      conn |> put_status(:ok) |> json(dto)
    else
      :not_found ->
        telemetry(started_at, project_id, %{
          outcome: :error,
          code: "not_found",
          retryable: false
        })

        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      {:error, {code, message}} ->
        telemetry(started_at, project_id, %{
          outcome: :error,
          code: Atom.to_string(code),
          retryable: false
        })

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: Atom.to_string(code), reason: message})
    end
  end

  defp telemetry(started_at, project_id, metadata) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Telemetry.usage_read(duration_ms, Map.put(metadata, :project_id, project_id))
  end
end
