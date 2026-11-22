defmodule ForemanServerWeb.RunController do
  @moduledoc """
  Run read-model endpoint.

  `GET /api/runs` returns projected runs with optional filters.
  `GET /api/runs/:id` returns the projected state for a single run.
  `GET /api/runs/:id/prs` returns the run's watched PRs as `ForemanServer.PrWatch.DTO`s.
  `GET /api/runs/:id/phases` returns the run's phases in workflow order with their own status.
  `GET /api/runs/:id/artifacts` lists the phase reports the run recorded (no content);
  `GET /api/runs/:id/artifacts/:phase_id` returns one report's content, read from the path the
  projection recorded for that phase and never from a client-supplied path.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

  def index(conn, params) do
    opts =
      []
      |> maybe_put_opt(:status, Map.get(params, "status"))
      |> maybe_put_opt(:project_id, Map.get(params, "project_id"))
      |> maybe_put_limit(Map.get(params, "limit"))

    conn
    |> put_status(:ok)
    |> json(%{runs: ProjectionStore.list_runs(opts) |> stringify_keys()})
  end

  def show(conn, %{"id" => run_id}) do
    case ProjectionStore.run(run_id) do
      nil ->
        show_pending(conn, run_id)

      projection when is_map(projection) ->
        conn
        |> put_status(:ok)
        |> json(%{run: stringify_keys(projection)})
    end
  end

  # `task.approve` returns a run id before admission has produced a run. A run
  # waiting on a refused admission (run limit, cap, pause) or a slot is queued
  # or deferred, not missing: 200 with that status instead of a 404 that never
  # resolves. Anything else is a genuine 404.
  defp show_pending(conn, run_id) do
    case ProjectionStore.pending_run(run_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "run_not_found", run_id: run_id})

      pending ->
        conn |> put_status(:ok) |> json(%{run: stringify_keys(pending)})
    end
  end

  def prs(conn, %{"id" => run_id}) do
    case ForemanServer.PrWatch.DTO.fetch(run_id) do
      {:ok, body} ->
        conn |> put_status(:ok) |> json(body)

      {:error, :run_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "run_not_found", run_id: run_id})

      # TRD-031 (AC-005-3): unreadable means unknown, never an empty list.
      {:error, {:projection_unavailable, cause}} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "projection_unavailable",
          status: "unknown",
          run_id: run_id,
          cause: cause
        })
    end
  end

  def phases(conn, %{"id" => run_id}) do
    cond do
      ProjectionStore.run(run_id) != nil ->
        body = ForemanServer.RunPhases.build(run_id, ProjectionStore.phases_for_run(run_id))
        conn |> put_status(:ok) |> json(body)

      # Queued or deferred: admitted nothing yet, so no phase has started.
      ProjectionStore.pending_run(run_id) != nil ->
        conn |> put_status(:ok) |> json(ForemanServer.RunPhases.build(run_id, []))

      true ->
        conn |> put_status(:not_found) |> json(%{error: "run_not_found", run_id: run_id})
    end
  end

  def artifacts(conn, %{"id" => run_id}) do
    case run_phases(run_id) do
      {:ok, phases} ->
        conn |> put_status(:ok) |> json(ForemanServer.RunArtifacts.list(run_id, phases))

      :run_not_found ->
        run_not_found(conn, run_id)
    end
  end

  def artifact(conn, %{"id" => run_id, "phase_id" => phase_id}) do
    with {:ok, phases} <- run_phases(run_id),
         {:ok, body} <- ForemanServer.RunArtifacts.read(run_id, phase_id, phases) do
      conn |> put_status(:ok) |> json(body)
    else
      :run_not_found ->
        run_not_found(conn, run_id)

      {:error, reason} when reason in [:phase_not_found, :artifact_not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: Atom.to_string(reason), run_id: run_id, phase_id: phase_id})
    end
  end

  # A queued or deferred run has admitted nothing yet, so it has no phases: an empty list, not a 404.
  defp run_phases(run_id) do
    cond do
      ProjectionStore.run(run_id) != nil -> {:ok, ProjectionStore.phases_for_run(run_id)}
      ProjectionStore.pending_run(run_id) != nil -> {:ok, []}
      true -> :run_not_found
    end
  end

  defp run_not_found(conn, run_id) do
    conn |> put_status(:not_found) |> json(%{error: "run_not_found", run_id: run_id})
  end

  defp maybe_put_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_limit(opts, nil), do: opts
  defp maybe_put_limit(opts, ""), do: opts

  defp maybe_put_limit(opts, value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> Keyword.put(opts, :limit, limit)
      _ -> opts
    end
  end

  # Only plain maps have their keys stringified. A struct inside the projection (the run's
  # `usage` is a `%ForemanServer.Usage{}`) is not enumerable: it is left for Jason, which
  # encodes it through the struct's own `Jason.Encoder`.
  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
