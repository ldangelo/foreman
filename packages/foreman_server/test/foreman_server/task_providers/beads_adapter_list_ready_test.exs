defmodule ForemanServer.TaskProviders.BeadsAdapterListReadyTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError

  @cache_name :foreman_server_json_schema_cache

  setup_all do
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
    {:ok, _telemetry_apps} = Application.ensure_all_started(:telemetry)
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

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    start_supervised!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      stop_schema_cache()
    end)

    :ok
  end

  test "happy path returns three blocked Issue structs with all 12 fields populated" do
    start_schema_cache!()

    cached_database_path = "/abs/cache/./ready/../beads.sqlite3"
    project_config = register_project!("proj-happy", cached_database_path)

    payload = [
      %{
        "id" => "bead-101",
        "title" => "Ship TRD-011",
        "status" => "open",
        "priority" => 2,
        "dependencies" => ["opaque:dep-1", "dep/2"],
        "assignee" => "leo",
        "description" => "List ready issues",
        "notes" => "Keep dependency ids opaque",
        "design" => "Use cached config",
        "labels" => ["backend", "beads"],
        "metadata" => %{
          "provider_id" => "beads",
          "created_at" => "2026-08-06T12:00:00Z",
          "updated_at" => "2026-08-06T13:00:00Z",
          "database_path" => "/br/dbs/ready.sqlite3"
        }
      },
      %{
        "id" => "bead-102",
        "title" => "Cover empty projects",
        "status" => "blocked",
        "priority" => 4,
        "dependencies" => ["opaque:dep-3"],
        "assignee" => nil,
        "description" => "Second issue",
        "notes" => nil,
        "design" => "Schema-backed mapping",
        "labels" => ["tests"],
        "metadata" => %{
          "provider_id" => "beads",
          "created_at" => "2026-08-06T14:00:00Z",
          "updated_at" => "2026-08-06T14:30:00Z",
          "database_path" => "/br/dbs/ready.sqlite3"
        }
      },
      %{
        "id" => "bead-103",
        "title" => "Retain metadata",
        "status" => "open",
        "priority" => 0,
        "dependencies" => [],
        "assignee" => "mox",
        "description" => nil,
        "notes" => "Third issue",
        "design" => nil,
        "labels" => [],
        "metadata" => %{
          "provider_id" => "beads",
          "created_at" => "2026-08-06T15:00:00Z",
          "updated_at" => "2026-08-06T15:05:00Z",
          "database_path" => "/br/dbs/ready.sqlite3"
        }
      }
    ]

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:ready, %{database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, issues} = BeadsAdapter.list_ready(project_config, [])

    assert issues == [
             %Issue{
               id: "bead-101",
               title: "Ship TRD-011",
               status: "blocked",
               priority: 2,
               dependencies: ["opaque:dep-1", "dep/2"],
               dependents: [],
               assignee: "leo",
               description: "List ready issues",
               notes: "Keep dependency ids opaque",
               design: "Use cached config",
               labels: ["backend", "beads"],
               metadata: %{
                 "provider_id" => "beads",
                 "created_at" => "2026-08-06T12:00:00Z",
                 "updated_at" => "2026-08-06T13:00:00Z",
                 "database_path" => "/br/dbs/ready.sqlite3"
               }
             },
             %Issue{
               id: "bead-102",
               title: "Cover empty projects",
               status: "blocked",
               priority: 4,
               dependencies: ["opaque:dep-3"],
               dependents: [],
               assignee: nil,
               description: "Second issue",
               notes: nil,
               design: "Schema-backed mapping",
               labels: ["tests"],
               metadata: %{
                 "provider_id" => "beads",
                 "created_at" => "2026-08-06T14:00:00Z",
                 "updated_at" => "2026-08-06T14:30:00Z",
                 "database_path" => "/br/dbs/ready.sqlite3"
               }
             },
             %Issue{
               id: "bead-103",
               title: "Retain metadata",
               status: "blocked",
               priority: 0,
               dependencies: [],
               dependents: [],
               assignee: "mox",
               description: nil,
               notes: "Third issue",
               design: nil,
               labels: [],
               metadata: %{
                 "provider_id" => "beads",
                 "created_at" => "2026-08-06T15:00:00Z",
                 "updated_at" => "2026-08-06T15:05:00Z",
                 "database_path" => "/br/dbs/ready.sqlite3"
               }
             }
           ]
  end

  test "re-asserts blocked status even when br reports open" do
    start_schema_cache!()

    project_config = register_project!("proj-blocked", "/abs/blocked/path.db")

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/blocked/path.db"}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout:
           Jason.encode!([
             %{
               "id" => "bead-201",
               "title" => "Schema says ready",
               "status" => "open",
               "priority" => 1,
               "dependencies" => [],
               "assignee" => "operator",
               "description" => "Needs defensive status handling",
               "notes" => "br says open",
               "design" => "adapter says blocked",
               "labels" => ["ready"],
               "metadata" => %{}
             }
           ]),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, [%Issue{id: "bead-201", status: "blocked", priority: 1} = issue]} =
             BeadsAdapter.list_ready(project_config, [])

    assert issue.dependencies == []
    assert issue.assignee == "operator"
    assert issue.dependents == []
  end

  test "preserves dependency ids as opaque strings exactly as br returned them" do
    start_schema_cache!()

    project_config = register_project!("proj-deps", "/abs/dependencies/path.db")

    dependency_ids = [
      "dep:001",
      "dep/2",
      "task-0003",
      "12345",
      "space separated",
      "pipe|delimited"
    ]

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/dependencies/path.db"}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout:
           Jason.encode!([
             %{
               "id" => "bead-301",
               "title" => "Opaque dependency ids",
               "status" => "open",
               "priority" => 3,
               "dependencies" => dependency_ids,
               "assignee" => nil,
               "description" => nil,
               "notes" => nil,
               "design" => nil,
               "labels" => [],
               "metadata" => %{}
             }
           ]),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, [%Issue{dependencies: returned_dependency_ids}]} =
             BeadsAdapter.list_ready(project_config, [])

    assert returned_dependency_ids == dependency_ids
  end

  test "returns {:ok, []} for an empty project" do
    start_schema_cache!()

    project_config = register_project!("proj-empty", "/abs/empty/path.db")

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/empty/path.db"}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: "[]", stderr: "", exit_code: 0}}
    end)

    assert {:ok, []} == BeadsAdapter.list_ready(project_config, [])
  end

  test "returns SCHEMA_VALIDATION_FAILED with missing_fields when br returns malformed payload" do
    start_schema_cache!()

    project_config = register_project!("proj-validation", "/abs/validation/path.db")

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/validation/path.db"}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout:
           Jason.encode!([
             %{
               "id" => "bead-401",
               "status" => "open",
               "priority" => 2,
               "dependencies" => [],
               "assignee" => nil,
               "description" => nil,
               "notes" => nil,
               "design" => nil,
               "labels" => [],
               "metadata" => %{}
             }
           ]),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.list_ready(project_config, [])

    assert provider_error.code == "SCHEMA_VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.command == "br ready"
    assert provider_error.context.missing_fields == ["title"]
  end

  test "consumes the cached absolute database_path established at registration verbatim" do
    start_schema_cache!()

    cached_database_path = "/abs/cached/path.db"
    project_config = register_project!("proj-x", cached_database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:ready, %{database_path: cached_database_path}}
      assert runner_project_config == %{"database_path" => cached_database_path}
      assert opts == [timeout_ms: 30_000]

      {:ok, %{stdout: "[]", stderr: "", exit_code: 0}}
    end)

    assert {:ok, []} == BeadsAdapter.list_ready(project_config, [])
  end

  defp register_project!(project_id, database_path) do
    assert :ok =
             Registry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => database_path
             })

    assert Registry.routing_snapshot()[project_id] == BeadsAdapter

    assert {:active, %{provider_module: BeadsAdapter, config: project_config}} =
             :sys.get_state(Registry).per_project[project_id]

    assert project_config == %{"database_path" => database_path}
    project_config
  end

  defp start_schema_cache! do
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)
  end

  defp expect_schema_boot_fetches do
    expect(BrRunnerMock, :cmd, 4, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name))}}
    end)
  end

  defp schema_document("ready-issue") do
    %{
      "type" => "object",
      "required" => [
        "id",
        "title",
        "status",
        "priority",
        "dependencies",
        "assignee",
        "description",
        "notes",
        "design",
        "labels",
        "metadata"
      ],
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "priority" => %{"type" => "integer"},
        "dependencies" => %{"type" => "array"},
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
      }
    }
  end

  defp schema_document("issue-details") do
    %{
      "type" => "object",
      "required" => ["id", "description"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("error") do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{
        "code" => %{"type" => "string"},
        "message" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("commands") do
    %{
      "type" => "object",
      "metadata" => %{"contractVersion" => "br.capabilities.v1"},
      "properties" => %{
        "commands" => %{"type" => "array"}
      }
    }
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
