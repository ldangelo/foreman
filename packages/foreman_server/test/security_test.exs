defmodule ForemanServer.SecurityTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, WorkerProtocol}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-security-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.delete_env(:foreman_server, :auth_token)
    Application.delete_env(:foreman_server, :remote_access_enabled)
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :auth_token)
      Application.delete_env(:foreman_server, :remote_access_enabled)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "worker start scopes project and run secrets while stripping forbidden variables" do
    assert {:ok, %{event: event}} =
             WorkerProtocol.start_phase("developer", %{
               "run_id" => "run-secure",
               "project_id" => "project-secure",
               "worker_id" => "worker-secure",
               "env" => %{"SAFE_BASE" => "base", "AWS_ACCESS_KEY_ID" => "host-leak"},
               "project_secrets" => %{
                 "PROJECT_TOKEN" => "project-secret",
                 "SSH_AUTH_SOCK" => "sock"
               },
               "run_secrets" => %{"RUN_TOKEN" => "run-secret", "GITHUB_TOKEN" => "gh"}
             })

    assert event.payload.prepared_env == %{
             "FOREMAN_PROJECT_ID" => "project-secure",
             "FOREMAN_RUN_ID" => "run-secure",
             "PROJECT_TOKEN" => "project-secret",
             "RUN_TOKEN" => "run-secret",
             "SAFE_BASE" => "base"
           }

    assert event.payload.scoped_secret_keys == %{project: ["PROJECT_TOKEN"], run: ["RUN_TOKEN"]}

    assert event.payload.stripped_env_keys == [
             "AWS_ACCESS_KEY_ID",
             "GITHUB_TOKEN",
             "SSH_AUTH_SOCK"
           ]

    refute Map.has_key?(event.payload.prepared_env, "FOREMAN_SERVER_AUTH_TOKEN")
  end

  test "remote access requires a configured auth token" do
    Application.put_env(:foreman_server, :remote_access_enabled, true)
    refute ForemanServer.Security.remote_access_ready?()

    assert_raise ArgumentError, ~r/FOREMAN_SERVER_AUTH_TOKEN is required/, fn ->
      ForemanServer.Http.Endpoint.child_spec(ip: {0, 0, 0, 0}, port: 0)
    end

    Application.put_env(:foreman_server, :auth_token, "remote-secret")
    assert ForemanServer.Security.remote_access_ready?()

    assert %{start: {Bandit, :start_link, _}} =
             ForemanServer.Http.Endpoint.child_spec(ip: {0, 0, 0, 0}, port: 0)
  end

  test "destructive commands record authorization and audit events after execution" do
    assert {:ok, %{event: event, audit_events: [authorization, audit]}} =
             CommandRouter.handle(%{
               command_id: "cmd-close-secure",
               command_type: "task.close",
               payload: %{task_id: "task-secure"},
               metadata: %{actor: "operator@example.com", correlation_id: "corr-secure"}
             })

    assert event.event_type == "TaskUpdated"
    assert authorization.event_type == "AuthorizationChecked"
    assert audit.event_type == "AuditRecorded"
    assert authorization.payload.actor == "operator@example.com"
    assert authorization.payload.decision == "allowed"
    assert authorization.payload.target == %{type: :task_id, id: "task-secure"}
    assert audit.payload.resulting_event_type == "TaskUpdated"

    event_types = Enum.map(EventStore.all(), & &1.event_type)
    assert event_types == ["TaskUpdated", "AuthorizationChecked", "AuditRecorded"]

    audits = ProjectionStore.snapshot().authorization_audits
    assert Enum.map(audits, & &1.event_type) == ["AuthorizationChecked", "AuditRecorded"]
  end
end
