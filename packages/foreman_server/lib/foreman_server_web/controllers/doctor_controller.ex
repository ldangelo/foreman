defmodule ForemanServerWeb.DoctorController do
  @moduledoc """
  `GET /api/doctor[?project=<id>]` - the checks `foreman doctor` can honestly
  perform, composed from existing seams:

    * `server` - the request itself reached the server;
    * `event_store` - the read model answers (`ProjectionStore.queue_status/0`);
    * `provider.<name>` - one row per jido_harness provider
      (`MCP.Tools.Doctor.rows/0`, the same data as the `foreman_doctor` MCP tool);
    * `workflows` - the workflow catalog has manifests installed;
    * `workflows.bead_types` - which bead types BeadsWatcher dispatches (each
      mapped to its workflow) and which it holds for want of a workflow,
      derived from the manifests' own `task_types:` (`TaskProviders.BeadTypeEligibility`);
      `warn` only when no type maps at all, since an unmapped type is by design;
    * `workflow.<file>` - one `warn` row per manifest the catalog REFUSED to
      load (`Catalog.invalid/0`), carrying the file's validation error;
    * `notifier` - outbound notifications: `ok` when they are off or on and able
      to deliver, `warn` when messaging is enabled but its config is invalid, the
      notifier or the dispatcher process is down, or events were refused
      (`Notifier.status/0`; it never names a destination);
    * `effect_keys` - started and ambiguous effect keys
      (`MCP.Tools.Doctor.unresolved_effect_keys/0`): `ok` with the count in the title
      (informational, so `foreman doctor --strict` stays green) and the store line, the Phase 1
      gating line (`Doctor.gating_line/0`: durable store required and met or not; a switch that
      is not a boolean is read as on and says so) and one line per key in `detail`
      (`<class> run=<id> status=<run status> key=<key> key_status=<started|ambiguous>
      decision=<not_done|none> writer=<alive|dead|none>`, `Doctor.effect_entry_line/1`); `warn` only when the
      keys cannot be read (the detail then still carries the gating line);
    * `pr_observation` - what shows a head change, a new check result or a published
      report without anyone approving (a fix push is re-read by the watcher; any other push
      is seen only by the poll loop or a verified webhook): the watcher
      (`PrWatcher.enabled?/0`, on by default), the monitor (`PrMonitor.enabled?/0`, opt-in)
      and whether `FOREMAN_GITHUB_WEBHOOK_SECRET` is set (never its value); `warn` when
      the watcher is off. The merge gate does not depend on any of them: approval re-reads
      GitHub;
    * `project.recommendations` - with `?project=`, counts of setup
      recommendations by severity (`Projects.Recommendations`).

  Each check is `%{id, status: ok|warn|fail, title, detail}`. Pi SDK, DB
  integrity, zombie-run, stale-worktree and auto-fix checks do NOT exist.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.TaskProviders.BeadTypeEligibility
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
        provider_checks() ++
        workflow_checks() ++
        [notifier_check(), effect_keys_check(), pr_observation_check()] ++ project_check

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

  defp effect_keys_check do
    case safely(&Doctor.unresolved_effect_keys/0) do
      {:ok, {:ok, entries}} ->
        lines = [
          Doctor.store_line(),
          Doctor.gating_line() | Enum.map(Doctor.effect_entry_lines(entries), &("  " <> &1))
        ]

        check(
          "effect_keys",
          :ok,
          "Unresolved effect keys: #{length(entries)}",
          Enum.join(lines, "\n")
        )

      _unreadable ->
        check(
          "effect_keys",
          :warn,
          "Unresolved effect keys could not be read",
          "The idempotency store did not answer, so ambiguous effect keys are unknown.\n" <>
            Doctor.gating_line()
        )
    end
  end

  defp pr_observation_check do
    watcher = ForemanServer.PrWatcher.enabled?()
    monitor = ForemanServer.PrMonitor.enabled?()
    webhook = webhook_secret_set?()
    {gated, unreadable} = gated_projects()

    detail =
      Enum.join(
        [
          "watcher: #{on_off(watcher)} (FOREMAN_PR_WATCHER_ENABLED; on by default; re-reads the PR when a fix jobsite ends)",
          "monitor: #{on_off(monitor)} (FOREMAN_PR_MONITOR_ENABLED=true; polls for a head that moves for any other reason)",
          "webhook secret: #{if webhook, do: "set", else: "not set"} (FOREMAN_GITHUB_WEBHOOK_SECRET; without it /webhooks/github answers 503)",
          "The merge gate does not depend on these: approval re-reads GitHub."
        ] ++ unreadable_lines(unreadable) ++ Enum.flat_map(gated, &gated_lines/1),
        "\n"
      )

    cond do
      unreadable != nil ->
        check(
          "pr_observation",
          :warn,
          "Gated projects could not be read: #{unreadable}",
          detail
        )

      gated != [] and not monitor and not webhook ->
        check(
          "pr_observation",
          :warn,
          "Gated project(s) #{Enum.join(gated, ", ")}: neither the monitor nor the webhook is on, " <>
            "so a head or check change is not observed",
          detail
        )

      watcher ->
        check(
          "pr_observation",
          :ok,
          "PR observation: #{summary(monitor, webhook)}",
          detail
        )

      true ->
        check(
          "pr_observation",
          :warn,
          "PR watcher is off: fix pushes and PR events are not observed",
          detail
        )
    end
  end

  # `{names, nil}`, or `{[], reason}` when the projection cannot be read: an unreadable
  # projection must not look like "no gated project", so the row says so and warns.
  # Archived projects are skipped (they take no PRs); names are sorted.
  defp gated_projects do
    names =
      for project <- ProjectionStore.list_projects(),
          not archived?(project),
          ForemanServer.ProjectSettings.from_config(Map.get(project, :config)).required_checks !=
            nil do
        to_string(
          Map.get(project, :name) || Map.get(project, :id) || Map.get(project, :project_id)
        )
      end

    {Enum.sort(names), nil}
  catch
    :exit, reason -> {[], inspect(reason, limit: 5)}
  end

  defp archived?(project),
    do: Map.get(project, :status) == "archived" or Map.get(project, :archived?) == true

  defp unreadable_lines(nil), do: []
  defp unreadable_lines(reason), do: ["gated projects could not be read: #{reason}"]

  defp gated_lines(name) do
    durable =
      case ForemanServer.Idempotency.KeyStore.require_durable() do
        :ok ->
          []

        {:error, {:store_not_durable, _note}} ->
          [
            "gated project #{name}: the idempotency store is not durable (see the Phase 1 gating line)"
          ]
      end

    [
      "gated project #{name}: required_checks is set; a PR with more than 100 checks is read from " <>
        "the newest 100 only, so a required check outside them is checks_truncated and not eligible."
      | durable
    ]
  end

  defp summary(true, true), do: "watcher on, monitor on, webhook secret set"
  defp summary(true, false), do: "watcher on, monitor on, webhook secret not set"
  defp summary(false, true), do: "watcher on, monitor off, webhook secret set"
  defp summary(false, false), do: "watcher on, monitor off, webhook secret not set"

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"

  defp webhook_secret_set? do
    case Application.get_env(:foreman_server, :github_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> true
      _ -> false
    end
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
        "(provider #{provider}); last: #{inspect(stats.last_error, limit: 20)}" <>
        unresolved_note(stats)
    )
  end

  defp notifier_row(%{
         messaging: {:enabled, provider},
         stats: %{skipped: %{project_unresolved: unresolved}}
       })
       when unresolved > 0 do
    check(
      "notifier",
      :warn,
      "Notifications were dropped",
      "#{unresolved} event(s) named a project the server does not know since it started, so no " <>
        "notification was sent (provider #{provider})."
    )
  end

  defp notifier_row(%{messaging: {:enabled, provider}, stats: stats}) do
    check("notifier", :ok, "Notifications are on (#{provider})", stats_detail(stats))
  end

  defp unresolved_note(%{skipped: %{project_unresolved: n}}) when n > 0,
    do: "; #{n} more event(s) named a project the server does not know and were dropped"

  defp unresolved_note(_stats), do: ""

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
    [workflows_check(), bead_types_check() | invalid_workflow_checks()]
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

  # Informational, not a gate: an unmapped type is the documented not-applicable
  # category (such a bead is held, never dispatched), so it must not turn `foreman
  # doctor --strict` red on a stock install where `task` is unmapped by design.
  # Only "nothing at all maps" is a warning, because then BeadsWatcher can
  # dispatch no bead whatever its type.
  defp bead_types_check do
    case safely(&BeadTypeEligibility.report/0) do
      {:ok, %BeadTypeEligibility{mapped: []} = report} ->
        check(
          "workflows.bead_types",
          :warn,
          "No workflow maps any bead type",
          "BeadsWatcher can dispatch no bead. " <> BeadTypeEligibility.summarize(report)
        )

      {:ok, %BeadTypeEligibility{mapped: mapped, unmapped: unmapped} = report} ->
        check(
          "workflows.bead_types",
          :ok,
          "Bead types: #{length(mapped)} mapped to a workflow, #{length(unmapped)} held",
          BeadTypeEligibility.summarize(report)
        )

      :error ->
        check(
          "workflows.bead_types",
          :warn,
          "Bead type mapping unknown",
          "The catalog did not answer."
        )
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
