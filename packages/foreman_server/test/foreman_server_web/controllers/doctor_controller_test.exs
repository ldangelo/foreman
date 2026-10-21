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
end
