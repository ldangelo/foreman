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
               "env" => %{
                 "SAFE_BASE" => "base",
                 "AWS_ACCESS_KEY_ID" => "host-leak",
                 "FOREMAN_SERVER_AUTH_TOKEN" => "server-token"
               },
               "project_secrets" => %{
                 "PROJECT_TOKEN" => "project-secret",
                 "SSH_AUTH_SOCK" => "sock",
                 "FOREMAN_SERVER_AUTH_TOKEN" => "project-server-token"
               },
               "run_secrets" => %{
                 "RUN_TOKEN" => "run-secret",
                 "GITHUB_TOKEN" => "gh",
                 "FOREMAN_SERVER_AUTH_TOKEN" => "run-server-token"
               }
             })

    assert event.payload.prepared_env == %{
             "FOREMAN_PROJECT_ID" => "[REDACTED]",
             "FOREMAN_RUN_ID" => "[REDACTED]",
             "PROJECT_TOKEN" => "[REDACTED]",
             "RUN_TOKEN" => "[REDACTED]",
             "SAFE_BASE" => "[REDACTED]"
           }

    assert event.payload.prepared_env_keys == [
             "FOREMAN_PROJECT_ID",
             "FOREMAN_RUN_ID",
             "PROJECT_TOKEN",
             "RUN_TOKEN",
             "SAFE_BASE"
           ]

    assert event.payload.scoped_secret_keys == %{project: ["PROJECT_TOKEN"], run: ["RUN_TOKEN"]}

    assert event.payload.stripped_env_keys == [
             "AWS_ACCESS_KEY_ID",
             "FOREMAN_SERVER_AUTH_TOKEN",
             "GITHUB_TOKEN",
             "SSH_AUTH_SOCK"
           ]

    refute Map.has_key?(event.payload.prepared_env, "FOREMAN_SERVER_AUTH_TOKEN")
    refute "FOREMAN_SERVER_AUTH_TOKEN" in event.payload.prepared_env_keys

    assert_persisted_payloads_exclude_secret_values([
      "project-secret",
      "run-secret",
      "server-token",
      "project-server-token",
      "run-server-token"
    ])
  end

  test "worker secret scopes do not leak across project and run starts" do
    assert {:ok, %{event: first}} =
             WorkerProtocol.start_phase("developer", %{
               "run_id" => "run-one",
               "project_id" => "project-one",
               "worker_id" => "worker-one",
               "project_secrets" => %{"PROJECT_ONE_TOKEN" => "p1"},
               "run_secrets" => %{"RUN_ONE_TOKEN" => "r1"}
             })

    assert {:ok, %{event: second}} =
             WorkerProtocol.start_phase("developer", %{
               "run_id" => "run-two",
               "project_id" => "project-two",
               "worker_id" => "worker-two",
               "project_secrets" => %{"PROJECT_TWO_TOKEN" => "p2"},
               "run_secrets" => %{"RUN_TWO_TOKEN" => "r2"}
             })

    assert first.payload.prepared_env["PROJECT_ONE_TOKEN"] == "[REDACTED]"
    assert first.payload.prepared_env["RUN_ONE_TOKEN"] == "[REDACTED]"
    refute Map.has_key?(first.payload.prepared_env, "PROJECT_TWO_TOKEN")
    refute Map.has_key?(first.payload.prepared_env, "RUN_TWO_TOKEN")

    assert second.payload.prepared_env["PROJECT_TWO_TOKEN"] == "[REDACTED]"
    assert second.payload.prepared_env["RUN_TWO_TOKEN"] == "[REDACTED]"
    refute Map.has_key?(second.payload.prepared_env, "PROJECT_ONE_TOKEN")
    refute Map.has_key?(second.payload.prepared_env, "RUN_ONE_TOKEN")

    assert_persisted_payloads_exclude_secret_values(["p1", "r1", "p2", "r2"])
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

  defp assert_persisted_payloads_exclude_secret_values(secret_values) do
    persisted = inspect(%{events: EventStore.all(), projection: ProjectionStore.snapshot()})

    Enum.each(secret_values, fn secret_value ->
      refute persisted =~ secret_value
    end)
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

    assert {:ok, rebuilt} = EventStore.rebuild_projections()
    rebuilt_audits = rebuilt.authorization_audits
    assert Enum.map(rebuilt_audits, & &1.event_type) == ["AuthorizationChecked", "AuditRecorded"]
    assert Enum.map(rebuilt_audits, & &1.command_id) == ["cmd-close-secure", "cmd-close-secure"]

    assert Enum.map(rebuilt_audits, & &1.actor) == [
             "operator@example.com",
             "operator@example.com"
           ]

    assert Enum.map(rebuilt_audits, & &1.decision) == ["allowed", "allowed"]

    assert Enum.map(rebuilt_audits, & &1.target) == [
             %{type: :task_id, id: "task-secure"},
             %{type: :task_id, id: "task-secure"}
           ]

    assert List.last(rebuilt_audits).resulting_event_type == "TaskUpdated"
  end
end
