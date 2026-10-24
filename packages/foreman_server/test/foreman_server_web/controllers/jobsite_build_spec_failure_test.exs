defmodule ForemanServerWeb.JobsiteBuildSpecFailureTest do
  # foreman-bg2kq. A build_spec refusal (here: the project's network policy is not
  # supported by the host sandbox) used to leave no event at all, so the id the
  # caller was handed answered 404 forever. POST /api/jobsites holds its 202 until
  # the refusal is recorded, so the id must already resolve to a failed jobsite
  # carrying the typed reason when the caller has it: no polling.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.CommandGateway
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "jobsite-build-spec-failure-token"

  setup do
    ProjectionStoreReset.reset!()
    project_id = "bsf-project-#{System.unique_integer([:positive])}"
    repo = Path.join(System.tmp_dir!(), "jobsite-bsf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "project.register-#{project_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.register",
               payload: %{project_id: project_id, path: repo}
             })

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "project.environment.set-#{project_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.environment.set",
               payload: %{project_id: project_id, network: %{mode: "none"}}
             })

    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_jobsites = Application.get_env(:foreman_server, :jobsites)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    Application.put_env(:foreman_server, :jobsites,
      allow_remote_start: true,
      allow_host_sandbox: true,
      max_concurrent_jobsites: 5
    )

    on_exit(fn ->
      restore(:api_bearer_token, previous_token)
      restore(:jobsites, previous_jobsites)
      File.rm_rf!(repo)
      ProjectionStoreReset.reset!()
    end)

    %{project_id: project_id}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp authed do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  test "a build_spec refusal after the 202 is readable as a failed jobsite with its typed reason",
       %{project_id: project_id} do
    conn =
      post(
        authed(),
        "/api/jobsites",
        Jason.encode!(%{
          "project_id" => project_id,
          "prompt" => "Fix",
          "sandbox" => "host",
          "agent" => %{"provider" => "claude", "model" => "sonnet"}
        })
      )

    assert %{"id" => id} = json_response(conn, 202)

    shown = authed() |> get("/api/jobsites/#{id}") |> json_response(200)

    assert %{
             "status" => "failed",
             "project_id" => ^project_id,
             "last_error" => %{"code" => "network_policy_unsupported"}
           } = shown
  end
end
