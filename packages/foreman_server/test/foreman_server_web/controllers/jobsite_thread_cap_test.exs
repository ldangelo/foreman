defmodule ForemanServerWeb.JobsiteThreadCapTest do
  # The project's daily thread cap is enforced on the jobsite door: the start that
  # would exceed it is answered 429 `thread_cap_reached` (retryable after the UTC
  # reset), audited, and leaves no JobsiteStarted. The projected limits show it.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, EventStore, Jobsite, ProjectionStore}
  alias ForemanServer.Jobsite.Executor
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "jobsite-thread-cap-token"

  setup do
    ProjectionStoreReset.reset!()
    project_id = "cap-project-#{System.unique_integer([:positive])}"

    # A directory that is NOT a git repo: an accepted start gets to the executor,
    # whose worktree creation fails fast, without ever launching an agent.
    repo = Path.join(System.tmp_dir!(), "jobsite-cap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    for {type, payload} <- [
          {"project.register", %{path: repo}},
          {"project.update", %{daily_thread_cap: 1}}
        ] do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "#{type}-#{project_id}",
                 aggregate_id: "project:#{project_id}",
                 type: type,
                 payload: Map.put(payload, :project_id, project_id)
               })
    end

    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_jobsites = Application.get_env(:foreman_server, :jobsites)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    Application.put_env(:foreman_server, :jobsites,
      allow_remote_start: true,
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

  defp post_spec(project_id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/jobsites",
      Jason.encode!(%{
        "project_id" => project_id,
        "prompt" => "Fix",
        "agent" => %{"provider" => "claude", "model" => "sonnet"}
      })
    )
  end

  test "the (cap+1)th jobsite of the day is 429 and starts nothing", %{project_id: project_id} do
    assert %{"id" => first_id} = json_response(post_spec(project_id), 202)
    await(fn -> Enum.any?(Jobsite.list(), &(Map.get(&1, :jobsite_id) == first_id)) end)

    conn = post_spec(project_id)
    assert %{"error" => "thread_cap_reached", "message" => message} = json_response(conn, 429)
    assert message =~ "daily thread cap of 1"

    assert Enum.count(Jobsite.list(), &(Map.get(&1, :project_id) == project_id)) == 1

    assert {:ok, [_one]} =
             EventStore.read_stream_forward("jobsite:#{first_id}", 0, 1) |> started_only()

    assert %{cap_reached?: true, threads_started_today: 1} =
             ProjectionStore.project_limits(project_id)
  end

  test "reserve_thread is idempotent per jobsite id and a project-less jobsite is not counted", %{
    project_id: project_id
  } do
    assert :ok = Executor.reserve_thread("js-idem", project_id: project_id)
    assert :ok = Executor.reserve_thread("js-idem", project_id: project_id)

    assert {:error, %{code: :thread_cap_reached}} =
             Executor.reserve_thread("js-other", project_id: project_id)

    assert :ok = Executor.reserve_thread("js-none", [])
  end

  defp await(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && await(fun, tries - 1)
    end
  end

  defp started_only({:ok, events}),
    do: {:ok, Enum.filter(events, &(&1.event_type == "JobsiteStarted"))}

  defp started_only(other), do: other
end
