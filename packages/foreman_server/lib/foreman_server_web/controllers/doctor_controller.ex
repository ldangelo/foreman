defmodule ForemanServerWeb.DoctorController do
  @moduledoc """
  `GET /api/doctor[?project=<id>]` - the checks `foreman doctor` can honestly
  perform, composed from existing seams:

    * `server` - the request itself reached the server;
    * `event_store` - the read model answers (`ProjectionStore.queue_status/0`);
    * `provider.<name>` - one row per jido_harness provider
      (`MCP.Tools.Doctor.rows/0`, the same data as the `foreman_doctor` MCP tool);
    * `workflows` - the workflow catalog has manifests installed;
    * `workflow.<file>` - one `warn` row per manifest the catalog REFUSED to
      load (`Catalog.invalid/0`), carrying the file's validation error;
    * `notifier` - outbound notifications: `ok` when they are off or on and able
      to deliver, `warn` when messaging is enabled but its config is invalid, the
      notifier or the dispatcher process is down, or events were refused
      (`Notifier.status/0`; it never names a destination);
    * `project.recommendations` - with `?project=`, counts of setup
      recommendations by severity (`Projects.Recommendations`).

  Each check is `%{id, status: ok|warn|fail, title, detail}`. Pi SDK, DB
  integrity, zombie-run, stale-worktree and auto-fix checks do NOT exist.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.LoadError
  alias ForemanServerWeb.MCP.Tools.Doctor

  def show(conn, params) do
    project_check =
      case params["project"] do
        id when is_binary(id) and id != "" -> [project_check(id)]
        _ -> []
      end

    checks =
      [check("server", :ok, "Server reachable", "The server answered this request.")] ++
        [event_store_check()] ++
        provider_checks() ++ workflow_checks() ++ [notifier_check()] ++ project_check

    case Enum.find(project_check, &(&1["status"] == "not_found")) do
      nil -> conn |> put_status(:ok) |> json(%{checks: checks})
      _ -> conn |> put_status(:not_found) |> json(%{error: "project_not_found"})
    end
  end

  defp event_store_check do
    ProjectionStore.queue_status()
    check("event_store", :ok, "Read model reachable", "The projection store answered.")
  catch
    :exit, reason ->
      check("event_store", :fail, "Read model unreachable", inspect(reason))
  end

  # Notifications are optional, so "off" is a healthy answer. What must not look healthy is the
  # silent kind of off: enabled, yet unable to deliver (bad config, the notifier or the
  # dispatcher down) or refusing events. The detail never holds a destination: the config error
  # is redacted and names no URL, and the provider is named, not its endpoint.
  defp notifier_check do
    case safely(&ForemanServer.Notifier.status/0) do
      {:ok, status} ->
        notifier_row(status)

      :error ->
        check("notifier", :warn, "Notifier status unknown", "The notifier did not answer.")
    end
  end

  defp notifier_row(%{messaging: :disabled}) do
    check(
      "notifier",
      :ok,
      "Notifications are off",
      "Outbound notifications are disabled (`config :foreman_server, :messaging, enabled: true` turns them on)."
    )
  end

  defp notifier_row(%{messaging: {:invalid, reason}}) do
    check(
      "notifier",
      :warn,
      "Notification config is invalid",
      "Nothing can be delivered until it is fixed: #{inspect(reason, limit: 20)}"
    )
  end

  defp notifier_row(%{notifier: :stopped, messaging: {:enabled, provider}}) do
    check(
      "notifier",
      :warn,
      "Notifier is not running",
      "Messaging is on (#{provider}) but ForemanServer.Notifier is stopped, so no event becomes a notification."
    )
  end

  defp notifier_row(%{dispatcher: :stopped, messaging: {:enabled, provider}}) do
    check(
      "notifier",
      :warn,
      "Messaging dispatcher is not running",
      "Messaging is on (#{provider}) but ForemanServer.Messaging.Dispatcher is stopped, so enqueued notifications are never sent."
    )
  end

  defp notifier_row(%{messaging: {:enabled, provider}, stats: %{errors: errors} = stats})
       when errors > 0 do
    check(
      "notifier",
      :warn,
      "Notifications were refused",
      "#{errors} event(s) could not be turned into a notification since the server started " <>
        "(provider #{provider}); last: #{inspect(stats.last_error, limit: 20)}"
    )
  end

  defp notifier_row(%{messaging: {:enabled, provider}, stats: stats}) do
    check("notifier", :ok, "Notifications are on (#{provider})", stats_detail(stats))
  end

  defp stats_detail(nil), do: "The notifier and the dispatcher are running."

  defp stats_detail(%{notified: notified, skipped: skipped}) do
    skips = Enum.map_join(skipped, ", ", fn {reason, count} -> "#{reason} #{count}" end)

    "#{notified} enqueued since the server started" <>
      if(skips == "", do: ".", else: "; skipped by #{skips}.")
  end

  defp provider_checks do
    case safely(&Doctor.rows/0) do
      {:ok, rows} ->
        for {:provider, name, status, hint} <- rows do
          case status do
            :installed ->
              check("provider.#{name}", :ok, "#{name} installed", "#{name} is available.")

            :not_installed ->
              check("provider.#{name}", :warn, "#{name} not installed", to_string(hint))
          end
        end

      :error ->
        [check("providers", :warn, "Provider readiness unknown", "The readiness probe failed.")]
    end
  end

  defp workflow_checks do
    [workflows_check() | invalid_workflow_checks()]
  end

  defp workflows_check do
    case safely(&Catalog.installed?/0) do
      {:ok, true} ->
        check("workflows", :ok, "Workflows installed", "The workflow catalog has manifests.")

      {:ok, false} ->
        check("workflows", :warn, "No workflows installed", "Run `foreman workflow install`.")

      :error ->
        check("workflows", :warn, "Workflow catalog unknown", "The catalog did not answer.")
    end
  end

  # A refused manifest is still refused; doctor's job is to say so and why.
  defp invalid_workflow_checks do
    case safely(&Catalog.invalid/0) do
      {:ok, errors} ->
        for %LoadError{} = error <- errors do
          check(
            "workflow.#{error.filename}",
            :warn,
            invalid_title(error),
            LoadError.describe(error)
          )
        end

      :error ->
        [
          check(
            "workflows.invalid",
            :warn,
            "Invalid workflows unknown",
            "The catalog did not answer, so refused manifests cannot be listed."
          )
        ]
    end
  end

  # Two different truths: a manifest that never loaded cannot start; an edit that
  # failed over a loaded one leaves the previous version running.
  defp invalid_title(%LoadError{serving_previous: true, filename: filename}),
    do:
      "Workflow #{filename}: the latest edit is invalid; its previous valid version is still served"

  defp invalid_title(%LoadError{serving_previous: false, filename: filename}),
    do: "Workflow #{filename} is invalid and was not loaded"

  defp project_check(id) do
    case Recommendations.recommend_bounded(id) do
      {:ok, recs} ->
        counts = Enum.frequencies_by(recs, & &1.severity)
        actions = Map.get(counts, :action, 0)
        warns = Map.get(counts, :warn, 0)
        infos = Map.get(counts, :info, 0)

        status = if actions + warns > 0, do: :warn, else: :ok

        check(
          "project.recommendations",
          status,
          "Project #{id} setup",
          "#{actions} action, #{warns} warn, #{infos} info recommendations. " <>
            "Run `foreman project recommend #{id}`."
        )

      {:error, :project_not_found} ->
        %{"id" => "project.recommendations", "status" => "not_found"}

      {:error, :timeout} ->
        check("project.recommendations", :warn, "Project setup unknown", "The check timed out.")
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  catch
    _kind, _reason -> :error
  end

  defp check(id, status, title, detail),
    do: %{"id" => id, "status" => Atom.to_string(status), "title" => title, "detail" => detail}
end
