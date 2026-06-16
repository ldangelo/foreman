defmodule ForemanServer.IntegrationIngestionTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, IntegrationIngestion, ProjectionStore}

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

    assert {:ok, %{duplicate: false, task_id: task_id, dedupe_key: dedupe_key}} =
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

    assert {:ok,
            %{task_id: github_task, dedupe_key: "github:github.com/fortium/foreman:17:labeled"}} =
             IntegrationIngestion.ingest(%{
               "source" => "github",
               "site" => "github.com/fortium/foreman",
               "external_id" => "17",
               "project_id" => "foreman",
               "event_type" => "labeled",
               "external_link" => "https://github.com/fortium/foreman/issues/17",
               "payload" => %{"label" => "ready"}
             })

    snapshot = ProjectionStore.snapshot()

    assert snapshot.tasks[jira_task].external_link ==
             "https://fortium.atlassian.net/browse/FORE-123"

    assert snapshot.tasks[jira_task].dedupe_key == "jira:fortium.atlassian.net:FORE-123:31"

    assert snapshot.tasks[github_task].external_link ==
             "https://github.com/fortium/foreman/issues/17"

    assert snapshot.tasks[github_task].source == "github"
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
