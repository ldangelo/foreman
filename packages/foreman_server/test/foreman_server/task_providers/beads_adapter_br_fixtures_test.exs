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
