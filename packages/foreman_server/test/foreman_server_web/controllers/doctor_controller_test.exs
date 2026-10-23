defmodule ForemanServerWeb.DoctorControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

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
  end
end
