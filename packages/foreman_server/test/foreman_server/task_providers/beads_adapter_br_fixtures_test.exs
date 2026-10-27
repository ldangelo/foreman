defmodule ForemanServer.TaskProviders.BeadsAdapterBrFixturesTest do
  @moduledoc """
  Drives `BeadsAdapter` with stdout captured verbatim from a real `br`
  (`test/fixtures/br/README.md`), including the real `br schema` documents.

  These tests exist because stubs with hand-written JSON let the adapter drift
  from what `br` actually prints (#610 shipped green against a shape `br`
  never emits). Nothing here fabricates `br` output.
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TestSupport.BrFixtures

  @cache_name :foreman_server_json_schema_cache
  @db "/abs/fixtures/beads.db"
  @project "proj-br-fixtures"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      stop_schema_cache()
    end)

    assert :ok = Registry.register_for_project(@project, BeadsAdapter, %{database_path: @db})
    :ok
  end

  describe "get/2 against real `br show --json`" do
    test "plain issue (no labels, dependencies or dependents keys)" do
      install_stub(show: "show_plain.json")
      fixture = BrFixtures.issue!("show_plain.json")

      refute Map.has_key?(fixture, "dependencies")
      refute Map.has_key?(fixture, "dependents")

      assert {:ok, %Issue{} = issue} = BeadsAdapter.get(fixture["id"], config())

      assert %Issue{
               id: id,
               title: "Plain fixture issue",
               status: "open",
               priority: 2,
               dependencies: [],
               dependents: [],
               labels: []
             } = issue

      assert id == fixture["id"]
      assert issue.description == fixture["description"]
    end

    test "issue with labels" do
      install_stub(show: "show_labels_with_dependency.json")
      fixture = BrFixtures.issue!("show_labels_with_dependency.json")

      assert {:ok, %Issue{labels: labels, id: id}} = BeadsAdapter.get(fixture["id"], config())
      assert labels == ["foreman-exec", "foreman-gap"]
      assert id == fixture["id"]
    end

    test "issue with a dependency (and no dependents key)" do
      install_stub(show: "show_labels_with_dependency.json")
      fixture = BrFixtures.issue!("show_labels_with_dependency.json")
      [dep] = fixture["dependencies"]

      assert {:ok, %Issue{dependencies: [%Issue{} = nested], dependents: []}} =
               BeadsAdapter.get(fixture["id"], config())

      assert nested.id == dep["id"]
      assert nested.title == dep["title"]
      assert nested.status == dep["status"]
      assert nested.priority == dep["priority"]
    end

    test "issue with a dependent (and no dependencies key)" do
      install_stub(show: "show_with_dependent.json")
      fixture = BrFixtures.issue!("show_with_dependent.json")
      [dependent] = fixture["dependents"]

      assert {:ok, %Issue{dependencies: [], dependents: [%Issue{} = nested]}} =
               BeadsAdapter.get(fixture["id"], config())

      assert nested.id == dependent["id"]
      assert nested.title == dependent["title"]
    end

    test "issue with comments (extra `comments` key is tolerated)" do
      install_stub(show: "show_with_comments.json")
      fixture = BrFixtures.issue!("show_with_comments.json")
      assert length(fixture["comments"]) == 2

      assert {:ok, %Issue{id: id, title: "Commented issue", priority: 3, dependencies: []}} =
               BeadsAdapter.get(fixture["id"], config())

      assert id == fixture["id"]
    end
  end

  describe "create/2 against real `br create --json`" do
    for {file, title, labels} <- [
          {"create_plain.json", "Plain fixture issue", []},
          {"create_labels.json", "Labelled fixture issue", ["foreman-exec", "foreman-gap"]}
        ] do
      test "#{file} decodes to the created issue" do
        file = unquote(file)
        title = unquote(title)
        labels = unquote(labels)
        install_stub(create: file)
        fixture = BrFixtures.issue!(file)

        assert {:ok, %Issue{id: id, title: ^title, status: "open", labels: ^labels}} =
                 BeadsAdapter.create(@project, %{
                   title: title,
                   description: "body",
                   priority: 2,
                   task_type: "task",
                   task_id: "task-1",
                   command_id: "cmd-#{file}"
                 })

        assert id == fixture["id"]
      end
    end
  end

  describe "create/2 source_repo from the real agent_context string (foreman-yqgvw)" do
    test "the JSON-string agent_context in `br create --json` yields foreman:<task_id>" do
      install_stub(create: "create_plain.json")

      fixture = BrFixtures.issue!("create_plain.json")
      assert is_binary(fixture["agent_context"])

      assert {:ok, %Issue{metadata: %{source_repo: "foreman:t1"}}} =
               BeadsAdapter.create(@project, %{
                 title: "Plain fixture issue",
                 description: "body",
                 priority: 2,
                 task_type: "task",
                 task_id: "t1",
                 command_id: "cmd-yqgvw"
               })
    end
  end

  describe "annotate/3 against real `br comments add --json`" do
    test "a real comment-added response is accepted" do
      install_stub(comments_add: "comments_add.json")
      issue_id = BrFixtures.issue!("comments_add.json")["issue_id"]

      assert {:ok, %ForemanServer.TaskProvider.Comment{provider_issue_id: ^issue_id}} =
               BeadsAdapter.annotate(issue_id, "first comment", config())
    end
  end

  describe "list_ready/2 against real `br ready --json`" do
    test "every ready row decodes" do
      install_stub(ready: "ready.json")
      rows = BrFixtures.decode!("ready.json")
      assert rows != []

      assert {:ok, issues} = BeadsAdapter.list_ready(config(), [])
      assert Enum.map(issues, & &1.id) == Enum.map(rows, & &1["id"])
    end
  end

  describe "complete/3 and reopen/3 against real `br close|update --json`" do
    test "close output decodes to a closed issue" do
      install_stub(close: "close.json")
      fixture = BrFixtures.issue!("close.json")

      assert {:ok, %Issue{id: id, status: "closed"}} =
               BeadsAdapter.complete(fixture["id"], :ignored, config())

      assert id == fixture["id"]
    end

    test "update --status open output decodes to a reopened issue" do
      install_stub(update: "update_reopen.json")
      fixture = BrFixtures.issue!("update_reopen.json")

      assert {:ok, %Issue{id: id, status: "open"}} =
               BeadsAdapter.reopen(fixture["id"], "reopened for fixture", config())

      assert id == fixture["id"]
    end
  end

  describe "claim/3 and fail/3 against real `br update --json`" do
    test "update --claim output decodes to a claimed issue" do
      install_stub(update: "update_claim.json")
      fixture = BrFixtures.issue!("update_claim.json")

      assert {:ok, %Issue{id: id, status: "in_progress", assignee: "agent-7"}} =
               BeadsAdapter.claim(fixture["id"], "agent-7", Map.put(config(), :run_id, "run-fx"))

      assert id == fixture["id"]
    end

    test "update --status blocked output decodes to a failed (blocked) issue" do
      install_stub(update: "update_blocked.json")
      fixture = BrFixtures.issue!("update_blocked.json")

      assert {:ok, %Issue{id: id, status: "blocked"}} =
               BeadsAdapter.fail(
                 fixture["id"],
                 "blocked for fixture",
                 Map.put(config(), :run_id, "run-fx")
               )

      assert id == fixture["id"]
    end
  end

  describe "set_priority/3 against real `br update --priority --json`" do
    test "the real update acknowledgement is accepted and the priority is what was requested" do
      install_stub(set_priority: "update_priority.json")
      fixture = BrFixtures.issue!("update_priority.json")
      assert fixture["priority"] == 1

      assert :ok = BeadsAdapter.set_priority(fixture["id"], 1, config())
    end
  end

  describe "coordination_status/2 against real `br coordination status --json`" do
    test "no claims decodes to an empty list" do
      install_stub(coordination_status: "coordination_status_empty.json")
      assert %{"claims" => []} = BrFixtures.decode!("coordination_status_empty.json")

      assert {:ok, []} = BeadsAdapter.coordination_status(config())
    end

    test "a claimed issue decodes to an Issue carrying the dependency counts" do
      install_stub(coordination_status: "coordination_status_claimed.json")
      [claim] = BrFixtures.decode!("coordination_status_claimed.json")["claims"]

      assert {:ok, [%Issue{id: id, status: "in_progress"} = issue]} =
               BeadsAdapter.coordination_status(config())

      assert id == claim["issue"]["id"]
      assert issue.metadata["dependent_count"] == claim["issue"]["dependent_count"]
    end
  end

  describe "add_dependency/3 against real `br dep add --json`" do
    test "the real success ack (no id/title) is accepted" do
      install_stub(add_dependency: "dep_add.json")
      ack = BrFixtures.decode!("dep_add.json")

      assert :ok = BeadsAdapter.add_dependency(ack["issue_id"], ack["depends_on_id"], config())
    end

    test "a real error envelope (printed on stdout, nested under \"error\") maps to DEPENDENCY_CYCLE" do
      stdout = BrFixtures.read!("dep_add_cycle_error.json")

      stub(BrRunnerMock, :cmd, fn {:add_dependency, _}, _cfg, _opts ->
        {:error, %{stdout: stdout, stderr: "", exit_code: 5}}
      end)

      assert {:error,
              %ForemanServer.TaskProviders.ProviderError{
                code: "DEPENDENCY_CYCLE",
                context: %{id: "CYCLE_DETECTED", exit_code: 5}
              }} = BeadsAdapter.add_dependency("fx-aaa", "fx-bbb", config())
    end
  end

  defp config, do: %{database_path: @db}

  defp install_stub(responses) do
    stub(BrRunnerMock, :cmd, fn
      {:schema, %{schema: name}}, _cfg, _opts ->
        {:ok, %{stdout: BrFixtures.read!("schema_" <> String.replace(name, "-", "_") <> ".json")}}

      {action, _payload}, _cfg, _opts ->
        case Keyword.fetch(responses, action) do
          {:ok, file} -> {:ok, %{stdout: BrFixtures.read!(file), stderr: "", exit_code: 0}}
          :error -> flunk("unexpected br action #{inspect(action)}")
        end
    end)

    start_supervised!(JsonSchemaCache)
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
