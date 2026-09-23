defmodule ForemanServerWeb.OperatorDashboardTestGateway do
  def dispatch_operator(envelope) do
    send(
      Application.fetch_env!(:foreman_server, :operator_dashboard_test_pid),
      {:dashboard_command, envelope}
    )

    {:ok, %{accepted: true}}
  end
end

defmodule ForemanServerWeb.OperatorDashboardRejectingGateway do
  def dispatch_operator(envelope) do
    send(
      Application.fetch_env!(:foreman_server, :operator_dashboard_test_pid),
      {:dashboard_command, envelope}
    )

    {:error, {:phase_terminal, envelope.payload.run_id}}
  end
end

defmodule ForemanServerWeb.OperatorDashboardTest do
  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServerWeb.OperatorDashboard

  @token "operator-dashboard-test-token"

  setup do
    ProjectionStoreReset.reset!()
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_gateway = Application.get_env(:foreman_server, :command_gateway_module)
    previous_pid = Application.get_env(:foreman_server, :operator_dashboard_test_pid)

    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :operator_dashboard_test_pid, self())

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore_env(:api_bearer_token, previous_token)
      restore_env(:command_gateway_module, previous_gateway)
      restore_env(:operator_dashboard_test_pid, previous_pid)
    end)

    :ok
  end

  test "dashboard route is authenticated, separate from existing /dashboard, and renders empty state" do
    assert build_conn() |> get("/dashboard/runs") |> response(401) == "unauthorized"

    conn = build_conn() |> get("/dashboard/runs?token=#{@token}")
    assert html_response(conn, 200) =~ "Operator Run Dashboard"
    assert html_response(conn, 200) =~ "No runs found."

    jido = build_conn() |> get("/dashboard?token=#{@token}")
    assert html_response(jido, 200) =~ "Jido Live Dashboard"
  end

  test "list and detail DTOs use projections, durable logs, phase status, absent markers, and truncation metadata" do
    seed_run("run-dashboard", status: "in_progress")

    assert {:ok, [row]} = OperatorDashboard.list_runs(%{"limit" => "9999"})
    assert row.run_id == "run-dashboard"
    assert row.project_id == "project-1"
    assert row.workflow == "plan"
    assert row.task_label == "ad-hoc run"
    assert row.current_phase_name == "implement"
    assert row.actions.stop.enabled == true
    assert row.actions.resume.enabled == false

    assert {:ok, detail} = OperatorDashboard.run_detail("run-dashboard")
    assert detail.run.run_id == "run-dashboard"
    assert [%{name: "implement", status: "in_progress"}] = detail.phases
    assert {:ok, logs} = detail.logs
    assert logs.count == 1
    assert hd(logs.entries).content == "hello operator"
    assert logs.truncated == false

    assert {:error, :run_not_found} = OperatorDashboard.run_detail("missing")
    assert {:error, :run_not_found} = OperatorDashboard.run_logs("missing")
  end

  test "run actions dispatch exact command gateway envelopes and stop defaults to operator_pause" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      ForemanServerWeb.OperatorDashboardTestGateway
    )

    assert {:ok, %{command: command}} = OperatorDashboard.pause_run("run-1", "   ")
    assert command.type == "run.pause"
    assert command.aggregate_id == "run:run-1"
    assert command.payload.run_id == "run-1"
    assert command.payload.reason == "operator_pause"
    assert command.payload.actor == "operator_dashboard"
    assert_receive {:dashboard_command, ^command}

    assert {:ok, %{command: resume}} = OperatorDashboard.resume_run("run-1", "operator says go")
    assert resume.type == "run.resume"
    assert resume.payload.reason == "operator says go"
  end

  test "operator gateway validates pause and resume run aggregate ids before dispatch" do
    for type <- ["run.pause", "run.resume"] do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 type: type,
                 command_id: "dashboard-test-#{type}",
                 aggregate_id: "run:other",
                 payload: %{run_id: "run-1", reason: "operator"}
               })
    end
  end

  test "rejected command returns typed reason while preserving envelope" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      ForemanServerWeb.OperatorDashboardRejectingGateway
    )

    assert {:error, {:phase_terminal, "run-2"}, envelope} = OperatorDashboard.reset_run("run-2")
    assert envelope.type == "run.reset"
    assert_receive {:dashboard_command, ^envelope}
  end

  test "change evidence uses retained worktree and rejects missing worktree as typed unavailable" do
    tmp = Path.join(System.tmp_dir!(), "operator-dashboard-#{System.unique_integer([:positive])}")

    try do
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      {_, 0} = System.cmd("git", ["init"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "base\n")
      {_, 0} = System.cmd("git", ["add", "README.md"], cd: tmp)

      {_, 0} =
        System.cmd(
          "git",
          ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "base"],
          cd: tmp
        )

      {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "changed\n")

      {_, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-am",
            "change"
          ],
          cd: tmp
        )

      seed_run("run-evidence",
        status: "completed",
        worktree_path: tmp,
        base_ref: String.trim(base)
      )

      assert {:ok, %{state: :available, files: files}} =
               OperatorDashboard.change_evidence("run-evidence")

      assert [%{path: "README.md", status: "M"}] = files

      seed_run("run-no-worktree", status: "completed")

      assert {:ok, %{state: :worktree_missing}} =
               OperatorDashboard.change_evidence("run-no-worktree")
    after
      File.rm_rf!(tmp)
    end
  end

  defp seed_run(run_id, opts) do
    status = Keyword.get(opts, :status, "awaiting_worker")

    events =
      [
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, project_id: "project-1", workflow_name: "plan"}
        },
        %{
          event_type: "PhaseStarted",
          payload: %{
            phase_id: "#{run_id}-phase-1",
            run_id: run_id,
            index: 1,
            name: "implement",
            attempt: 1,
            artifact_template: "artifact.md"
          }
        },
        %{
          event_type: "WorkerStdout",
          payload: %{
            run_id: run_id,
            worker_id: "worker-1",
            sequence: 1,
            line: "hello operator",
            timestamp: "2026-09-23T00:00:00Z"
          }
        }
      ] ++ worktree_events(run_id, opts)

    assert :ok = ProjectionStore.apply_events(events)

    :sys.replace_state(ProjectionStore, fn state ->
      update_in(state, [:runs, run_id], fn run ->
        %{run | status: status, terminal?: status in ["completed", "failed"]}
      end)
    end)
  end

  defp worktree_events(run_id, opts) do
    case Keyword.get(opts, :worktree_path) do
      nil ->
        []

      path ->
        [
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{run_id}",
              project_id: "project-1",
              run_id: run_id,
              phase_id: "#{run_id}-phase-1",
              worktree_path: path,
              base_ref: Keyword.fetch!(opts, :base_ref),
              branch: "foreman/#{run_id}"
            }
          }
        ]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)
end
