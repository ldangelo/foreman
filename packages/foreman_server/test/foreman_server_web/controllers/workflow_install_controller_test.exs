defmodule ForemanServerWeb.WorkflowInstallControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint
  @token "workflow-install-controller-token"
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    File.mkdir_p!(Path.join(dir, "prompts"))

    for file <- ~w(implement.yaml verify.yaml fix.yaml prd.yaml prompts/implement.md) do
      File.write!(Path.join(dir, file), "x\n")
    end

    :ok
  end

  defp remove(body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post("/api/admin/workflows/remove", Jason.encode!(body))
  end

  defp files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.sort()
  end

  test "POST /workflows/remove with remove_all deletes the legacy files and reports them", %{
    tmp_dir: dir
  } do
    conn = remove(%{remove_all: true, target_dir: dir})

    assert %{"status" => "removed", "paths" => paths} = json_response(conn, 200)

    assert Enum.sort(paths) ==
             Enum.sort([
               Path.join(dir, "implement.yaml"),
               Path.join(dir, "verify.yaml"),
               Path.join([dir, "prompts", "implement.md"])
             ])

    assert files(dir) == [Path.join(dir, "fix.yaml"), Path.join(dir, "prd.yaml")]
  end

  test "POST /workflows/remove without an explicit remove_all: true is a 400 and removes nothing",
       %{tmp_dir: dir} do
    before = files(dir)

    for body <- [%{target_dir: dir}, %{remove_all: false, target_dir: dir}] do
      assert %{"error" => _} = json_response(remove(body), 400)
    end

    assert files(dir) == before
  end
end
