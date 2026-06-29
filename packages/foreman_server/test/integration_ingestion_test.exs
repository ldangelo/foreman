defmodule ForemanServer.IntegrationIngestionTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, IntegrationIngestion, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-integration-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    event_log_path = Path.join(tmp_dir, "events.term.log")

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, event_log_path: event_log_path}
  end

  test "sentinel threshold creates a deterministic bug task through Elixir commands" do
    assert {:error, {:threshold_not_reached, count: 2, threshold: 3}} =
             IntegrationIngestion.ingest(%{
               "source" => "sentinel",
               "external_id" => "mix-test:flaky",
               "project_id" => "foreman",
               "event_type" => "test_failed",
               "count" => 2,
               "threshold" => 3
             })

    assert {:ok,
            %{
              duplicate: false,
              task_id: task_id,
              dedupe_key: "sentinel:foreman:mix-test:flaky" = dedupe_key
            }} =
             IntegrationIngestion.ingest(%{
               "source" => "sentinel",
               "external_id" => "mix-test:flaky",
               "project_id" => "foreman",
               "event_type" => "test_failed",
               "count" => 3,
               "threshold" => 3,
               "title" => "Bug: mix test repeatedly fails"
             })

    snapshot = ProjectionStore.snapshot()
    assert snapshot.integration_dedupe[dedupe_key].task_id == task_id
    assert snapshot.tasks[task_id].task_type == "bug"
    assert snapshot.tasks[task_id].source == "sentinel"
    assert snapshot.tasks[task_id].title == "Bug: mix test repeatedly fails"
  end

  test "Jira and GitHub external transitions create tasks with links and dedupe keys" do
    jira = fixture()

    assert {:ok, %{task_id: jira_task, dedupe_key: "jira:fortium.atlassian.net:FORE-123:31"}} =
             IntegrationIngestion.ingest(jira)

    assert {:ok, %{task_id: github_task, dedupe_key: "github:fortium/foreman:evt-17"}} =
             IntegrationIngestion.ingest(%{
               "source" => "github",
               "repo" => "fortium/foreman",
               "event_id" => "evt-17",
               "external_id" => "17",
               "project_id" => "foreman",
               "event_type" => "labeled",
               "external_link" => "https://github.com/fortium/foreman/issues/17",
               "payload" => %{
                 "label" => "ready",
                 "description" => "GitHub issue body",
                 "labels" => ["github:bug", "github:ready"],
                 "priority" => 1
               }
             })

    snapshot = ProjectionStore.snapshot()

    assert snapshot.tasks[jira_task].external_link ==
             "https://fortium.atlassian.net/browse/FORE-123"

    assert snapshot.tasks[jira_task].dedupe_key == "jira:fortium.atlassian.net:FORE-123:31"

    assert snapshot.tasks[github_task].external_link ==
             "https://github.com/fortium/foreman/issues/17"

    assert snapshot.tasks[github_task].source == "github"
    assert snapshot.tasks[github_task].description == "GitHub issue body"
    assert snapshot.tasks[github_task].labels == ["github:bug", "github:ready"]
    assert snapshot.tasks[github_task].priority == 1
  end

  test "top-level external trigger command routes through integration ingestion" do
    assert {:ok, %{event: event, integration: %{task_id: task_id, duplicate: false}}} =
             CommandRouter.handle(%{
               command_type: "ExternalTriggerCommand",
               source: "github",
               repo: "fortium/foreman",
               event_id: "evt-command-top",
               external_id: "18-top",
               project_id: "foreman",
               event_type: "opened",
               url: "https://github.com/fortium/foreman/issues/18"
             })

    assert event.event_type == "IntegrationCommandIngested"
    assert ProjectionStore.snapshot().tasks[task_id].source == "github"

    assert ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-command-top"].task_id ==
             task_id

    assert {:ok, %{integration: %{duplicate: true, existing: existing}}} =
             CommandRouter.handle(%{
               "command_type" => "ExternalTriggerCommand",
               "source" => "github",
               "repo" => "fortium/foreman",
               "event_id" => "evt-command-top",
               "external_id" => "18-top",
               "project_id" => "foreman",
               "event_type" => "opened",
               "url" => "https://github.com/fortium/foreman/issues/18"
             })

    assert existing.task_id == task_id
  end

  test "envelope external trigger command routes through integration ingestion" do
    assert {:ok, %{event: event, integration: %{task_id: task_id, duplicate: false}}} =
             CommandRouter.handle(%{
               command_id: "cmd-ext-1",
               command_type: "ExternalTriggerCommand",
               payload: %{
                 "source" => "github",
                 "repo" => "fortium/foreman",
                 "event_id" => "evt-command",
                 "external_id" => "18",
                 "project_id" => "foreman",
                 "event_type" => "opened",
                 "url" => "https://github.com/fortium/foreman/issues/18"
               },
               metadata: %{"correlation_id" => "corr-ext-1"}
             })

    assert event.event_type == "IntegrationCommandIngested"
    assert ProjectionStore.snapshot().tasks[task_id].source == "github"

    assert {:ok, %{integration: %{duplicate: true, existing: existing}}} =
             CommandRouter.handle(%{
               command_id: "cmd-ext-2",
               command_type: "ExternalTriggerCommand",
               payload: %{
                 "source" => "github",
                 "repo" => "fortium/foreman",
                 "event_id" => "evt-command",
                 "external_id" => "18",
                 "project_id" => "foreman",
                 "event_type" => "opened",
                 "url" => "https://github.com/fortium/foreman/issues/18"
               }
             })

    assert existing.task_id == task_id
  end

  test "duplicate integration input returns existing projection without duplicate tasks or runs" do
    jira = fixture()

    assert {:ok, %{duplicate: false, task_id: task_id, dedupe_key: dedupe_key}} =
             IntegrationIngestion.ingest(jira)

    events_before = EventStore.all()
    task_count_before = map_size(ProjectionStore.snapshot().tasks)

    assert {:ok, %{duplicate: true, existing: existing}} = IntegrationIngestion.ingest(jira)
    assert existing.task_id == task_id
    assert existing.dedupe_key == dedupe_key
    assert EventStore.all() == events_before
    assert map_size(ProjectionStore.snapshot().tasks) == task_count_before
    assert ProjectionStore.snapshot().runs == %{}
  end

  test "rejects invalid external integration input" do
    for input <- [
          %{
            "source" => "jira",
            "external_id" => "FORE-999",
            "project_id" => "foreman",
            "event_type" => "transitioned",
            "transition_id" => "99",
            "site" => "fortium.atlassian.net"
          },
          %{
            "source" => "github",
            "repo" => "fortium/foreman",
            "event_id" => "evt-missing-link",
            "external_id" => "19",
            "project_id" => "foreman",
            "event_type" => "opened"
          }
        ] do
      assert {:error, {:missing_or_invalid, :external_link}} = IntegrationIngestion.ingest(input)
    end

    assert {:error, {:missing_or_invalid, :source}} =
             IntegrationIngestion.ingest(%{"project_id" => "foreman"})

    assert {:error, {:unsupported_integration_source, "slack"}} =
             IntegrationIngestion.ingest(%{
               "source" => "slack",
               "project_id" => "foreman",
               "external_id" => "1",
               "event_type" => "posted"
             })
  end

  test "dedupe recorded without task is recovered on retry" do
    input = fixture()
    dedupe_key = "jira:fortium.atlassian.net:FORE-123:31"

    task_id =
      "jira-#{:crypto.hash(:sha256, dedupe_key) |> Base.encode16(case: :lower) |> binary_part(0, 12)}"

    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "integration:#{dedupe_key}",
               event_type: "IntegrationCommandIngested",
               payload: %{
                 source: "jira",
                 external_id: "FORE-123",
                 project_id: "foreman",
                 event_type: "transitioned",
                 dedupe_key: dedupe_key,
                 idempotency_key: dedupe_key,
                 external_link: "https://fortium.atlassian.net/browse/FORE-123",
                 task_id: task_id,
                 command_type: "task.create"
               },
               metadata: %{
                 source: "test",
                 correlation_id: dedupe_key,
                 idempotency_key: dedupe_key
               }
             })

    assert is_nil(ProjectionStore.snapshot().tasks[task_id])

    assert {:ok, %{duplicate: false, recovered: true, task_id: ^task_id}} =
             IntegrationIngestion.ingest(input)

    assert ProjectionStore.snapshot().tasks[task_id].external_link ==
             "https://fortium.atlassian.net/browse/FORE-123"
  end

  test "ingested integration state rebuilds from durable events", %{
    event_log_path: event_log_path
  } do
    assert {:ok, %{task_id: task_id, dedupe_key: dedupe_key}} =
             IntegrationIngestion.ingest(fixture())

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)
    assert :ok = Application.start(:foreman_server)

    snapshot = ProjectionStore.snapshot()
    assert snapshot.integration_dedupe[dedupe_key].task_id == task_id
    assert snapshot.tasks[task_id].external_id == "FORE-123"
  end

  defp fixture do
    "test/fixtures/integration-jira-transition.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
