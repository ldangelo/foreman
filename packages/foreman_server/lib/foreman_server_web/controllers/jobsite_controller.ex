defmodule ForemanServerWeb.JobsiteController do
  @moduledoc """
  Remote ingress for Jobsite: validated JSON in, `Jobsite.run_async/1` underneath.

  Mounted behind `ForemanServerWeb.Plugs.RequireAuthenticated`, which fails
  CLOSED when no bearer token is configured (unlike `BearerAuth`, which is open
  by default for local dev). Starting a jobsite spends agent credits and runs a
  process on the server, so it additionally requires the operator flag
  `config :foreman_server, :jobsites, allow_remote_start: true` (default off).

  The caller never supplies code: the body goes through
  `ForemanServer.Jobsite.Spec.from_json/2`, which whitelists keys and rejects
  anything that would run on the server host.

  Every mutating request (start, pause, cancel, resume), accepted or rejected,
  is recorded on the audit stream (`ForemanServer.Aggregates.JobsiteAudit`) with
  the TCP peer address. Behind a reverse proxy that is the proxy's address, and
  the shared token carries no per-user identity, so the address is all "who"
  means here. Authentication failures are rejected by the plug before this
  controller runs and are therefore not audited. A failed audit write is logged
  at `error` and does not undo a request that already took effect.

  Status mapping: 400 missing/malformed required input, 403 forbidden by policy,
  404 unknown id, 409 wrong state, 422 invalid spec, 429 capacity, 502 the
  executor could not be started.
  """

  use ForemanServerWeb, :controller

  require Logger

  alias ForemanServer.Aggregates.JobsiteAudit
  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Error, Executor, Spec}

  @default_max_concurrent 3

  # POST /api/jobsites
  def create(conn, _params) do
    with :ok <- check_enabled(),
         :ok <- check_capacity(),
         {:ok, opts} <- Spec.from_json(conn.body_params),
         {:ok, id} <- Jobsite.run_async(opts) do
      audit(conn, "accepted", nil, id)

      conn
      |> put_status(:accepted)
      |> json(%{id: id})
    else
      {:error, %Error{} = error} -> reject(conn, error, nil)
    end
  end

  # GET /api/jobsites
  def index(conn, _params), do: json(conn, %{jobsites: Jobsite.list()})

  # GET /api/jobsites/:id
  def show(conn, %{"id" => id}) do
    case Jobsite.get(id) do
      nil -> error_response(conn, not_found(id))
      jobsite -> json(conn, jobsite)
    end
  end

  # POST /api/jobsites/:id/pause
  def pause(conn, %{"id" => id}), do: control(conn, id, :pause)

  # POST /api/jobsites/:id/cancel
  def cancel(conn, %{"id" => id}), do: control(conn, id, :cancel)

  # POST /api/jobsites/:id/resume
  def resume(conn, %{"id" => id}) do
    case Jobsite.resume_async(id) do
      {:ok, ^id} ->
        audit(conn, "accepted", nil, id)

        conn
        |> put_status(:accepted)
        |> json(%{id: id})

      {:error, %Error{} = error} ->
        reject(conn, error, id)
    end
  end

  # POST /api/jobsites/:id/merge  {"into": "<checked-out branch>"}
  def merge(conn, %{"id" => id}) do
    with {:ok, into} <- require_into(conn.body_params),
         {:ok, merged} <- Jobsite.merge_into(id, into) do
      audit(conn, "accepted", nil, id)
      json(conn, merged)
    else
      {:error, %Error{} = error} -> reject(conn, error, id)
    end
  end

  defp require_into(%{"into" => into}) when is_binary(into) and into != "", do: {:ok, into}

  defp require_into(%{"into" => _other}),
    do: {:error, Error.new(:into_invalid, "into must be a non-empty branch name", %{})}

  defp require_into(_params), do: {:error, Error.new(:into_missing, "into is required", %{})}

  defp control(conn, id, action) do
    with {:ok, reason} <- require_reason(conn.body_params),
         :ok <- require_running(id),
         :ok <- apply_control(action, id, reason) do
      audit(conn, "accepted", nil, id)
      json(conn, %{id: id, requested: Atom.to_string(action)})
    else
      {:error, %Error{} = error} -> reject(conn, error, id)
    end
  end

  defp apply_control(:pause, id, reason), do: Jobsite.pause(id, reason)
  defp apply_control(:cancel, id, reason), do: Jobsite.cancel(id, reason)

  # `Control.request/2` only records an intent in ETS: it neither knows whether
  # the jobsite exists nor whether an executor is alive to honor it. Without
  # this check a pause for an unknown or finished id would answer success.
  defp require_running(id) do
    cond do
      Jobsite.get(id) == nil ->
        {:error, not_found(id)}

      Executor.pid_for(id) == nil ->
        {:error,
         Error.new(:not_running, "jobsite #{id} has no running executor", %{jobsite_id: id})}

      true ->
        :ok
    end
  end

  defp require_reason(%{"reason" => reason}) when is_binary(reason) and reason != "",
    do: {:ok, reason}

  defp require_reason(%{"reason" => _other}),
    do: {:error, Error.new(:reason_invalid, "reason must be a non-empty string", %{})}

  defp require_reason(_params),
    do: {:error, Error.new(:reason_missing, "reason is required", %{})}

  defp check_enabled do
    if config(:allow_remote_start, false) == true do
      :ok
    else
      {:error,
       Error.new(
         :remote_start_disabled,
         "remote jobsite start is disabled; set config :foreman_server, :jobsites, allow_remote_start: true",
         %{}
       )}
    end
  end

  # Counted from the live-executor registry, read-then-start: two simultaneous
  # requests can both pass at max-1. Acceptable for the single trusted operator
  # this API targets; a hard bound would need a reservation in the supervisor.
  defp check_capacity do
    max = config(:max_concurrent_jobsites, @default_max_concurrent)
    running = Registry.count(ForemanServer.Jobsite.Registry)

    if running < max do
      :ok
    else
      {:error,
       Error.new(:jobsite_capacity_reached, "#{running} jobsites already running (max #{max})", %{
         running: running,
         max: max
       })}
    end
  end

  defp config(key, default) do
    :foreman_server |> Application.get_env(:jobsites, []) |> Keyword.get(key, default)
  end

  defp not_found(id),
    do: Error.new(:jobsite_not_found, "jobsite #{id} does not exist", %{jobsite_id: id})

  defp reject(conn, %Error{code: code} = error, jobsite_id) do
    audit(conn, "rejected", Atom.to_string(code), jobsite_id)
    error_response(conn, error)
  end

  defp error_response(conn, %Error{code: code, message: message}) do
    conn
    |> put_status(status_for(code))
    |> json(%{error: Atom.to_string(code), message: message})
  end

  defp status_for(code)
       when code in [
              :remote_start_disabled,
              :spec_forbidden_key,
              :spec_prompt_file_forbidden,
              :spec_env_not_allowed,
              :spec_sandbox_not_allowed,
              :spec_hooks_forbidden
            ],
       do: :forbidden

  defp status_for(code) when code in [:jobsite_not_found, :spec_project_not_found], do: :not_found

  defp status_for(code)
       when code in [
              :spec_project_id_missing,
              :spec_prompt_missing,
              :spec_agent_missing,
              :reason_missing,
              :reason_invalid
            ],
       do: :bad_request

  defp status_for(code)
       when code in [
              :not_resumable,
              :already_running,
              :not_running,
              :not_completed,
              :branch_missing,
              :merge_target_mismatch,
              :merge_conflict
            ],
       do: :conflict

  defp status_for(code) when code in [:into_missing, :into_invalid], do: :bad_request
  defp status_for(:git_failed), do: :internal_server_error

  defp status_for(:jobsite_capacity_reached), do: :too_many_requests
  defp status_for(:dispatch_rejected), do: :bad_gateway
  defp status_for(_other_validation_or_domain_error), do: :unprocessable_entity

  defp audit(conn, outcome, error_code, jobsite_id) do
    command = %{
      aggregate_id: JobsiteAudit.stream_id(),
      type: "jobsite.audit.record",
      command_id: "audit-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      payload: %{
        route: conn.request_path,
        method: conn.method,
        outcome: outcome,
        error_code: error_code,
        jobsite_id: jobsite_id,
        remote_address: conn.remote_ip |> :inet.ntoa() |> to_string()
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "jobsite audit write failed: #{inspect(reason)} (#{conn.method} #{conn.request_path}, #{outcome})"
        )

        :ok
    end
  end
end
