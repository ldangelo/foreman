defmodule ForemanServerWeb.JobsiteControllerTest do
  use ExUnit.Case, async: false

  import Mox
  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Aggregates.JobsiteAudit
  alias ForemanServer.EventStore
  alias ForemanServer.Jobsite
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TestSupport.BrFixtures
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "jobsite-controller-test-token"
  @project_id "remote-project"

  setup do
    ProjectionStoreReset.reset!()

    # A real directory that is NOT a git repository: an accepted start gets as far
    # as the executor, whose worktree creation then fails fast. That exercises the
    # whole request path without ever launching an agent.
    repo = Path.join(System.tmp_dir!(), "jobsite-ctl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    assert :ok =
             ProjectionStore.apply_events([
               %{event_type: "ProjectRegistered", payload: %{project_id: @project_id, path: repo}}
             ])

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

    %{repo: repo}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp authed do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp post_json(conn, path, body), do: post(conn, path, Jason.encode!(body))

  defp spec do
    %{
      "project_id" => @project_id,
      "prompt" => "Fix the bug",
      "agent" => %{"provider" => "claude", "model" => "sonnet"}
    }
  end

  defp audit_events do
    case EventStore.read_stream_forward(JobsiteAudit.stream_id(), 0, 99_999_999) do
      {:ok, events} -> Enum.map(events, &payload/1)
      {:error, :stream_not_found} -> []
    end
  end

  defp payload(%{data: data}) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.new(data, fn {key, value} -> {to_string(key), value} end)
  end

  defp audited(route, outcome, error_code) do
    Enum.filter(audit_events(), fn e ->
      e["route"] == route and e["outcome"] == outcome and e["error_code"] == error_code
    end)
  end

  defp await_terminal(id, deadline \\ System.monotonic_time(:millisecond) + 15_000) do
    case Jobsite.get(id) do
      %{status: status} = jobsite when status in ["completed", "failed"] ->
        jobsite

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("jobsite #{id} did not reach a terminal state: #{inspect(Jobsite.get(id))}")
        else
          Process.sleep(50)
          await_terminal(id, deadline)
        end
    end
  end

  describe "authentication fails closed" do
    test "no token configured => 401, never open" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      conn = build_conn() |> get("/api/jobsites")
      assert conn.status == 401
    end

    test "missing and wrong tokens => 401" do
      assert build_conn() |> get("/api/jobsites") |> Map.fetch!(:status) == 401

      conn =
        build_conn() |> put_req_header("authorization", "Bearer nope") |> get("/api/jobsites")

      assert conn.status == 401
    end

    test "start is rejected before the controller when unauthenticated" do
      before = length(audit_events())

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post_json("/api/jobsites", spec())

      assert conn.status == 401
      assert length(audit_events()) == before
    end
  end

  describe "POST /api/jobsites policy gates" do
    test "remote start disabled by default => 403 and an audited rejection" do
      Application.put_env(:foreman_server, :jobsites, [])
      before = length(audited("/api/jobsites", "rejected", "remote_start_disabled"))

      conn = post_json(authed(), "/api/jobsites", spec())

      assert %{"error" => "remote_start_disabled"} = json_response(conn, 403)
      assert length(audited("/api/jobsites", "rejected", "remote_start_disabled")) == before + 1
    end

    test "allow_remote_start must be exactly true, not merely truthy" do
      Application.put_env(:foreman_server, :jobsites, allow_remote_start: "yes")
      conn = post_json(authed(), "/api/jobsites", spec())
      assert %{"error" => "remote_start_disabled"} = json_response(conn, 403)
    end

    test "capacity reached => 429, audited, nothing started" do
      Application.put_env(:foreman_server, :jobsites,
        allow_remote_start: true,
        max_concurrent_jobsites: 0
      )

      before = length(audited("/api/jobsites", "rejected", "jobsite_capacity_reached"))
      jobsites_before = length(Jobsite.list())

      conn = post_json(authed(), "/api/jobsites", spec())

      assert %{"error" => "jobsite_capacity_reached"} = json_response(conn, 429)

      assert length(audited("/api/jobsites", "rejected", "jobsite_capacity_reached")) ==
               before + 1

      assert length(Jobsite.list()) == jobsites_before
    end
  end

  describe "POST /api/jobsites spec validation maps to distinct statuses" do
    test "missing project_id => 400" do
      conn = post_json(authed(), "/api/jobsites", Map.delete(spec(), "project_id"))
      assert %{"error" => "spec_project_id_missing"} = json_response(conn, 400)
    end

    test "unregistered project => 404" do
      conn = post_json(authed(), "/api/jobsites", Map.put(spec(), "project_id", "nope"))
      assert %{"error" => "spec_project_not_found"} = json_response(conn, 404)
    end

    test "host hooks (sh -c on the server) => 403 and audited" do
      before = length(audited("/api/jobsites", "rejected", "spec_hooks_forbidden"))
      hooks = %{"host" => %{"on_worktree_ready" => [%{"command" => "touch /tmp/pwned"}]}}

      conn = post_json(authed(), "/api/jobsites", Map.put(spec(), "hooks", hooks))

      assert %{"error" => "spec_hooks_forbidden"} = json_response(conn, 403)
      assert length(audited("/api/jobsites", "rejected", "spec_hooks_forbidden")) == before + 1
    end

    test "host sandbox is refused unless the operator enabled it => 403" do
      conn = post_json(authed(), "/api/jobsites", Map.put(spec(), "sandbox", "host"))
      assert %{"error" => "spec_sandbox_not_allowed"} = json_response(conn, 403)
    end

    test "unknown key => 422" do
      conn = post_json(authed(), "/api/jobsites", Map.put(spec(), "bogus", 1))
      assert %{"error" => "spec_unknown_key"} = json_response(conn, 422)
    end

    test "a non-object JSON body is rejected, not crashed on" do
      conn = post_json(authed(), "/api/jobsites", [1, 2, 3])
      assert conn.status in [400, 422]
    end
  end

  describe "accepted start" do
    test "returns 202 + id, audits acceptance with the jobsite id, and is readable" do
      conn = post_json(authed(), "/api/jobsites", spec())
      assert %{"id" => "js-" <> _ = id} = json_response(conn, 202)

      assert Enum.any?(audit_events(), fn e ->
               e["jobsite_id"] == id and e["outcome"] == "accepted" and e["method"] == "POST" and
                 e["remote_address"] == "127.0.0.1"
             end)

      # Let the (doomed, non-git) executor finish so it cannot leak into other tests.
      await_terminal(id)

      shown = authed() |> get("/api/jobsites/#{id}") |> json_response(200)
      assert shown["status"] == "failed"

      listed = authed() |> get("/api/jobsites") |> json_response(200)
      assert Enum.any?(listed["jobsites"], &(&1["jobsite_id"] == id or &1["id"] == id))
    end

    test "a failed jobsite whose error details hold structs and tuples is still readable, not a 500" do
      %{"id" => id} = authed() |> post_json("/api/jobsites", spec()) |> json_response(202)
      await_terminal(id)

      # What an agent runtime failure looks like once it reaches the projection:
      # structs and tuples, none of which Jason can encode.
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "JobsiteFailed",
                   payload: %{
                     jobsite_id: id,
                     code: "agent_failed",
                     message: "boom",
                     details: %{
                       error: struct(Jido.Harness.Error, message: "provider rejected"),
                       pair: {:exit, 1}
                     }
                   }
                 }
               ])

      shown = authed() |> get("/api/jobsites/#{id}") |> json_response(200)
      assert shown["last_error"]["code"] == "agent_failed"
      assert shown["last_error"]["details"]["error"]["message"] == "provider rejected"
      assert shown["last_error"]["details"]["pair"] == "{:exit, 1}"

      assert authed() |> get("/api/jobsites") |> json_response(200)
    end
  end

  describe "bead_id ownership (remote door)" do
    @db "/abs/jobsite-ctl/beads.db"
    @bead_id BrFixtures.issue!("show_plain.json")["id"]

    setup do
      {:ok, _} = Application.ensure_all_started(:mox)
      set_mox_global()
      previous_provider_config = Application.get_env(:foreman_server, :task_provider, [])

      Application.put_env(
        :foreman_server,
        :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1"],
        providers: []
      )

      stop_schema_cache()
      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      # Any br call this suite does not expect (a `create`, a comment, a show when
      # no bead_id was sent) fails the test.
      stub(BrRunnerMock, :cmd, fn request, config, opts ->
        flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, config, opts})}")
      end)

      on_exit(fn ->
        Application.put_env(:foreman_server, :task_provider, previous_provider_config)
        stop_schema_cache()
      end)

      :ok
    end

    defp stop_schema_cache do
      case Process.whereis(:foreman_server_json_schema_cache) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end

    defp register_provider! do
      assert :ok =
               Registry.register_for_project(@project_id, BeadsAdapter, %{database_path: @db})
    end

    # show: :found | :not_found | :locked
    defp stub_show(show) do
      test = self()

      stub(BrRunnerMock, :cmd, fn
        {:schema, %{schema: name}}, _cfg, _opts ->
          {:ok,
           %{stdout: BrFixtures.read!("schema_" <> String.replace(name, "-", "_") <> ".json")}}

        # The lookup must go through THIS project's database, in both the request
        # and the provider config; a lookup through any other project's db flunks.
        {:show, %{id: id, database_path: @db}}, %{database_path: @db}, _opts ->
          send(test, {:br, :show, id})

          case show do
            :found ->
              {:ok, %{stdout: BrFixtures.read!("show_plain.json"), stderr: "", exit_code: 0}}

            :not_found ->
              envelope =
                Jason.encode!(%{
                  "error" => %{
                    "code" => "ISSUE_NOT_FOUND",
                    "message" => "Issue not found: #{id}",
                    "hint" => "Run 'br list' to see available issues.",
                    "retryable" => false,
                    "context" => %{"searched_id" => id}
                  }
                })

              {:error, %{stdout: "", stderr: envelope, exit_code: 3}}

            :locked ->
              {:error, %{stdout: "", stderr: "db locked", exit_code: 1}}
          end

        other, cfg, _opts ->
          flunk("br call outside the project's database: #{inspect({other, cfg})}")
      end)

      start_supervised!(JsonSchemaCache)
    end

    defp with_bead(bead_id), do: Map.put(spec(), "bead_id", bead_id)

    test "a bead_id that does not exist in the project => 404, audited rejected, nothing started" do
      register_provider!()
      stub_show(:not_found)
      before = length(audited("/api/jobsites", "rejected", "spec_bead_not_found"))
      jobsites_before = length(Jobsite.list())

      conn = post_json(authed(), "/api/jobsites", with_bead("other-project-bead"))
      assert %{"error" => "spec_bead_not_found"} = json_response(conn, 404)

      assert_received {:br, :show, "other-project-bead"}
      assert length(audited("/api/jobsites", "rejected", "spec_bead_not_found")) == before + 1
      assert length(Jobsite.list()) == jobsites_before
    end

    test "an existing bead_id is accepted and the jobsite projection carries it" do
      register_provider!()
      stub_show(:found)

      conn = post_json(authed(), "/api/jobsites", with_bead(@bead_id))
      assert %{"id" => id} = json_response(conn, 202)
      assert_received {:br, :show, @bead_id}

      assert %{"bead_id" => @bead_id} =
               authed() |> get("/api/jobsites/#{id}") |> json_response(200)

      await_terminal(id)
    end

    test "no bead_id => the provider is never consulted" do
      # The suite stub flunks on any br call, and no provider is even registered.
      conn = post_json(authed(), "/api/jobsites", spec())
      assert %{"id" => id} = json_response(conn, 202)
      await_terminal(id)
    end

    test "no provider resolvable for the project => 503, audited rejected, not accepted" do
      before = length(audited("/api/jobsites", "rejected", "spec_bead_unavailable"))
      jobsites_before = length(Jobsite.list())

      conn = post_json(authed(), "/api/jobsites", with_bead(@bead_id))
      assert %{"error" => "spec_bead_unavailable"} = json_response(conn, 503)

      assert length(audited("/api/jobsites", "rejected", "spec_bead_unavailable")) == before + 1
      assert length(Jobsite.list()) == jobsites_before
    end

    test "a provider that cannot answer => 503, not accepted and not a not-found" do
      register_provider!()
      stub_show(:locked)

      conn = post_json(authed(), "/api/jobsites", with_bead(@bead_id))
      assert %{"error" => "spec_bead_unavailable"} = json_response(conn, 503)
    end
  end

  describe "read, pause, cancel, resume on ids that cannot take the action" do
    test "show unknown => 404" do
      conn = get(authed(), "/api/jobsites/js-does-not-exist")
      assert %{"error" => "jobsite_not_found"} = json_response(conn, 404)
    end

    test "pause/cancel unknown id => 404 (Control.request alone would have said ok)" do
      for action <- ["pause", "cancel"] do
        conn = post_json(authed(), "/api/jobsites/js-nope/#{action}", %{"reason" => "x"})
        assert %{"error" => "jobsite_not_found"} = json_response(conn, 404)
      end
    end

    test "pause without a reason => 400 before touching anything" do
      conn = post_json(authed(), "/api/jobsites/js-nope/pause", %{})
      assert %{"error" => "reason_missing"} = json_response(conn, 400)

      conn = post_json(authed(), "/api/jobsites/js-nope/pause", %{"reason" => ""})
      assert %{"error" => "reason_invalid"} = json_response(conn, 400)
    end

    test "finished jobsite: pause/cancel => 409 not_running, resume => 409 not_resumable" do
      %{"id" => id} = authed() |> post_json("/api/jobsites", spec()) |> json_response(202)
      await_terminal(id)

      for action <- ["pause", "cancel"] do
        conn = post_json(authed(), "/api/jobsites/#{id}/#{action}", %{"reason" => "late"})
        assert %{"error" => "not_running"} = json_response(conn, 409)
      end

      conn = post_json(authed(), "/api/jobsites/#{id}/resume", %{})
      assert %{"error" => "not_resumable"} = json_response(conn, 409)

      assert Enum.any?(
               audit_events(),
               &(&1["jobsite_id"] == id and &1["error_code"] == "not_resumable")
             )
    end

    test "resume unknown => 404" do
      conn = post_json(authed(), "/api/jobsites/js-nope/resume", %{})
      assert %{"error" => "jobsite_not_found"} = json_response(conn, 404)
    end

    test "resume forwards a JSON prompt: a blank or non-string one is rejected 422 before lookup" do
      for bad <- ["", "   ", 7] do
        conn = post_json(authed(), "/api/jobsites/js-nope/resume", %{"prompt" => bad})
        assert %{"error" => "spec_option_invalid"} = json_response(conn, 422)
      end
    end

    test "resume of a jobsite that never provisioned a worktree => 409 not_resumable, no executor" do
      id = "js-starting-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ForemanServer.CommandGateway.dispatch_system(%{
                 type: "jobsite.start",
                 command_id: "jobsite-controller-test:#{id}:start",
                 aggregate_id: "jobsite:#{id}",
                 payload: %{
                   jobsite_id: id,
                   repo_path: "/tmp/jobsite-ctl-no-such-repo",
                   strategy: "head",
                   max_iterations: 1
                 }
               })

      conn = post_json(authed(), "/api/jobsites/#{id}/resume", %{})
      assert %{"error" => "not_resumable", "message" => message} = json_response(conn, 409)
      assert message =~ "never provisioned a worktree"
      assert Jobsite.Executor.pid_for(id) == nil
    end

    test "resume is held to the remote-start flag, audited" do
      Application.put_env(:foreman_server, :jobsites, [])
      conn = post_json(authed(), "/api/jobsites/js-any/resume", %{})
      assert %{"error" => "remote_start_disabled"} = json_response(conn, 403)

      codes =
        for e <- audit_events(), e["route"] == "/api/jobsites/js-any/resume", do: e["error_code"]

      assert "remote_start_disabled" in codes
    end

    test "a rejected pause is audited" do
      post_json(authed(), "/api/jobsites/js-nope-audit/pause", %{"reason" => "x"})
      |> json_response(404)

      assert Enum.any?(
               audit_events(),
               &(&1["route"] == "/api/jobsites/js-nope-audit/pause" and
                   &1["error_code"] == "jobsite_not_found")
             )
    end

    test "merge: missing/blank target => 400, unknown id => 404, nothing merged" do
      conn = post_json(authed(), "/api/jobsites/js-nope/merge", %{})
      assert %{"error" => "into_missing"} = json_response(conn, 400)

      conn = post_json(authed(), "/api/jobsites/js-nope/merge", %{"into" => ""})
      assert %{"error" => "into_invalid"} = json_response(conn, 400)

      conn = post_json(authed(), "/api/jobsites/js-nope/merge", %{"into" => "main"})
      assert %{"error" => "jobsite_not_found"} = json_response(conn, 404)
    end

    test "merge of a jobsite that did not complete => 409 not_completed, audited" do
      %{"id" => id} = authed() |> post_json("/api/jobsites", spec()) |> json_response(202)
      await_terminal(id)

      conn = post_json(authed(), "/api/jobsites/#{id}/merge", %{"into" => "main"})
      assert %{"error" => "not_completed"} = json_response(conn, 409)

      assert Enum.any?(
               audit_events(),
               &(&1["jobsite_id"] == id and &1["error_code"] == "not_completed" and
                   &1["route"] == "/api/jobsites/#{id}/merge")
             )
    end
  end
end
