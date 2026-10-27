defmodule ForemanServerWeb.DoctorControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Messaging.Dispatcher
  alias ForemanServer.Notifier
  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "doctor-controller-token"
  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get(path)
    |> json_response(status)
  end

  test "reports only the checks it performs, each with a typed status" do
    %{"checks" => checks} = get_json("/api/doctor", 200)
    ids = Enum.map(checks, & &1["id"])

    assert "server" in ids and "event_store" in ids and "workflows" in ids
    assert Enum.any?(ids, &String.starts_with?(&1, "provider."))
    refute Enum.any?(ids, &(&1 =~ ~r/pi_sdk|zombie|worktree|integrity/))
    assert Enum.all?(checks, &(&1["status"] in ["ok", "warn", "fail"]))
  end

  test "?project= adds a recommendations summary; unknown project is 404", %{tmp_dir: repo} do
    id = "doctor-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: repo}}
      ])

    %{"checks" => checks} = get_json("/api/doctor?project=#{id}", 200)
    assert %{"detail" => detail} = Enum.find(checks, &(&1["id"] == "project.recommendations"))
    assert detail =~ "foreman project recommend #{id}"

    assert %{"error" => "project_not_found"} = get_json("/api/doctor?project=nope", 404)
  end

  describe "workflow manifests the catalog refused (foreman-gl3nu)" do
    setup %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "prompts"))

      File.write!(
        Path.join(tmp, "good.yaml"),
        "name: good\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      File.write!(
        Path.join(tmp, "lvclaude.yaml"),
        "name: lvclaude\nphases:\n  - name: a\n    command: /skill:x\n    provider: claude\n" <>
          "    models:\n      default: litellm-stack/smart_router\n"
      )

      server = :"doctor_catalog_#{System.unique_integer([:positive])}"
      previous = Application.get_env(:foreman_server, :workflow_catalog)
      Application.put_env(:foreman_server, :workflow_catalog, server)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:foreman_server, :workflow_catalog, previous),
          else: Application.delete_env(:foreman_server, :workflow_catalog)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!(
          {ForemanServer.Workflow.Catalog,
           name: server, catalog: ForemanServer.Workflow.AssetCatalog.new(tmp)}
        )
      end)

      :ok
    end

    test "each refused manifest gets its own warn row carrying the validation error" do
      %{"checks" => checks} = get_json("/api/doctor", 200)

      # The catalog still has a loaded manifest, so the summary row is unchanged...
      assert %{"status" => "ok", "title" => "Workflows installed"} =
               Enum.find(checks, &(&1["id"] == "workflows"))

      # ...and the refused one is no longer invisible.
      assert %{"status" => "warn", "title" => title, "detail" => detail} =
               Enum.find(checks, &(&1["id"] == "workflow.lvclaude.yaml"))

      assert title =~ "lvclaude.yaml is invalid and was not loaded"
      assert detail =~ "must be a bare model alias or id"
      refute Enum.any?(checks, &(&1["id"] == "workflow.good.yaml"))
    end

    test "a refused edit over a loaded manifest is titled as still-served, distinct from never-loaded" do
      File.write!(
        Path.join(ForemanServer.Workflow.Catalog.root(), "good.yaml"),
        "name: good\nphases:\n  - bogus line\n"
      )

      ExUnit.CaptureLog.capture_log(fn -> :ok = ForemanServer.Workflow.Catalog.reload() end)

      %{"checks" => checks} = get_json("/api/doctor", 200)

      assert %{"status" => "warn", "title" => stale_title, "detail" => stale_detail} =
               Enum.find(checks, &(&1["id"] == "workflow.good.yaml"))

      assert stale_title =~ "latest edit is invalid"
      assert stale_title =~ "previous valid version is still served"
      refute stale_title =~ "was not loaded"
      assert stale_detail =~ "unsupported phase entry"

      assert %{"title" => never_title} =
               Enum.find(checks, &(&1["id"] == "workflow.lvclaude.yaml"))

      assert never_title =~ "is invalid and was not loaded"
    end
  end

  # foreman-ireii: "no notifier status surface". Off is healthy; the silent kinds of off are not.
  describe "the notifier row" do
    setup do
      original = Application.get_env(:foreman_server, :messaging)

      on_exit(fn ->
        if original,
          do: Application.put_env(:foreman_server, :messaging, original),
          else: Application.delete_env(:foreman_server, :messaging)
      end)
    end

    defp notifier_row do
      %{"checks" => checks} = get_json("/api/doctor", 200)
      Enum.find(checks, &(&1["id"] == "notifier"))
    end

    defp configure_webhook(webhook) do
      Application.put_env(:foreman_server, :messaging,
        enabled: true,
        provider: :webhook,
        webhook: webhook
      )
    end

    defp start_pipeline do
      start_supervised!({Dispatcher, catch_up?: false, subscribe?: false})
      start_supervised!({Notifier, subscribe?: false})
    end

    test "notifications off is a healthy answer, said plainly" do
      Application.put_env(:foreman_server, :messaging, enabled: false)

      assert %{"status" => "ok", "title" => "Notifications are off"} = notifier_row()
    end

    test "enabled with the notifier down is a warning that names the provider, not its URL" do
      Application.put_env(:foreman_server, :messaging,
        enabled: true,
        provider: :slack,
        slack: [webhook_url: "https://hooks.slack.com/services/T0/B0/SECRETDOCTOR"]
      )

      assert %{"status" => "warn", "title" => "Notifier is not running", "detail" => detail} =
               notifier_row()

      assert detail =~ "slack"
      refute detail =~ "SECRETDOCTOR"
    end

    test "a config that cannot deliver is a warning with the reason, never the URL" do
      configure_webhook(url: "https://bot:hunter2@example.test/hook")

      assert %{
               "status" => "warn",
               "title" => "Notification config is invalid",
               "detail" => detail
             } = notifier_row()

      assert detail =~ "unsafe_url"
      assert detail =~ "userinfo"
      refute detail =~ "hunter2"
    end

    test "the dispatcher down is its own warning" do
      configure_webhook(url: "https://example.test/hook")
      start_supervised!({Notifier, subscribe?: false})

      assert %{"status" => "warn", "title" => "Messaging dispatcher is not running"} =
               notifier_row()
    end

    test "on and running is ok, with what the notifier has done since it started" do
      configure_webhook(url: "https://example.test/hook")
      start_pipeline()

      assert %{
               "status" => "ok",
               "title" => "Notifications are on (webhook)",
               "detail" => detail
             } = notifier_row()

      assert detail =~ "0 enqueued"
    end

    test "refused and dropped events both show in the row" do
      configure_webhook([])
      start_pipeline()

      for {run, project} <- [{"a", nil}, {"b", "no-such-project"}] do
        data = %{run_id: "run-doctor-#{run}-#{System.unique_integer([:positive])}", reason: "x"}
        data = if project, do: Map.put(data, :project_id, project), else: data
        send(Notifier, {:projection_event, %{event_type: "RunFailed", data: data}})
      end

      assert %{errors: 1, skipped: %{project_unresolved: 1}} = Notifier.stats()
      configure_webhook(url: "https://example.test/hook")

      assert %{"status" => "warn", "detail" => detail} = notifier_row()
      assert detail =~ "1 event(s) could not be turned"
      assert detail =~ "1 more event(s) named a project"
    end

    test "an event naming an unknown project is dropped and the row warns" do
      configure_webhook(url: "https://example.test/hook")
      start_pipeline()

      send(
        Notifier,
        {:projection_event,
         %{
           event_type: "RunFailed",
           data: %{
             run_id: "run-doctor-#{System.unique_integer([:positive])}",
             project_id: "no-such-project",
             reason: "x"
           }
         }}
      )

      assert %{skipped: %{project_unresolved: 1}} = Notifier.stats()

      assert %{"status" => "warn", "title" => "Notifications were dropped", "detail" => detail} =
               notifier_row()

      assert detail =~ "1 event(s)"
    end

    test "events refused since boot keep the row a warning after the config is fixed" do
      configure_webhook([])
      start_pipeline()
      run_id = "run-doctor-#{System.unique_integer([:positive])}"

      send(
        Notifier,
        {:projection_event, %{event_type: "RunFailed", data: %{run_id: run_id, reason: "x"}}}
      )

      # The call is answered after the event above was handled.
      assert %{errors: 1} = Notifier.stats()
      configure_webhook(url: "https://example.test/hook")

      assert %{"status" => "warn", "title" => "Notifications were refused", "detail" => detail} =
               notifier_row()

      assert detail =~ "1 event(s)"
      assert detail =~ "missing_field"
    end
  end

  # TRD-009 / REQ-008: `foreman doctor` is where the user guide sends an operator to
  # see which bead types dispatch, so the answer must be on it — derived from the
  # catalog's own manifests, informational (an unmapped type is by design), and a
  # warning only when nothing maps at all.
  describe "the bead types row (TRD-009)" do
    setup %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "prompts"))

      server = :"doctor_types_catalog_#{System.unique_integer([:positive])}"
      previous = Application.get_env(:foreman_server, :workflow_catalog)
      Application.put_env(:foreman_server, :workflow_catalog, server)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:foreman_server, :workflow_catalog, previous),
          else: Application.delete_env(:foreman_server, :workflow_catalog)
      end)

      {:ok, server: server}
    end

    defp start_types_catalog(server, tmp) do
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!(
          {ForemanServer.Workflow.Catalog,
           name: server,
           catalog: ForemanServer.Workflow.AssetCatalog.new(tmp),
           skills_target_dir: Path.join(tmp, "skills")}
        )
      end)
    end

    defp bead_types_row do
      %{"checks" => checks} = get_json("/api/doctor", 200)
      Enum.find(checks, &(&1["id"] == "workflows.bead_types"))
    end

    test "lists each mapped type with its workflow and each held type, as an ok row",
         %{server: server, tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "fixer.yaml"),
        "name: fixer\ntask_types: [bug, implement_trd]\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      start_types_catalog(server, tmp)

      assert %{"status" => "ok", "title" => title, "detail" => detail} = bead_types_row()
      assert title == "Bead types: 2 mapped to a workflow, 6 held"
      assert detail =~ "dispatched: bug -> fixer, implement_trd -> fixer"
      assert detail =~ "chore, docs, epic, feature, question, task"
    end

    test "follows the manifests: a type a manifest declares leaves the held list",
         %{server: server, tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "fixer.yaml"),
        "name: fixer\ntask_types: [bug]\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      start_types_catalog(server, tmp)
      assert %{"detail" => before_detail} = bead_types_row()
      assert before_detail =~ "chore"

      File.write!(
        Path.join(tmp, "housekeeping.yaml"),
        "name: housekeeping\ntask_types: [chore]\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      ExUnit.CaptureLog.capture_log(fn -> :ok = ForemanServer.Workflow.Catalog.reload() end)

      assert %{"detail" => after_detail} = bead_types_row()
      assert after_detail =~ "chore -> housekeeping"

      refute after_detail =~
               "held (no workflow maps them, so a labelled bead of these types is never dispatched): chore"
    end

    test "is a warning only when no manifest maps any type",
         %{server: server, tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "plain.yaml"),
        "name: plain\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      start_types_catalog(server, tmp)

      assert %{
               "status" => "warn",
               "title" => "No workflow maps any bead type",
               "detail" => detail
             } =
               bead_types_row()

      assert detail =~ "BeadsWatcher can dispatch no bead"
      assert detail =~ "dispatched: none"
    end
  end
end
