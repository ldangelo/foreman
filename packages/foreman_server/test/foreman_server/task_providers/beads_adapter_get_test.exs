defmodule ForemanServer.TaskProviders.BeadsAdapterGetTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemBrRunner

  @cache_name :foreman_server_json_schema_cache

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
    start_supervised!(Registry)

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "beads_adapter_get_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      System.put_env("PATH", original_path)
      stop_schema_cache()
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "happy path returns {:ok, %Issue{}} with all 12 canonical fields populated", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/get/happy.db"
    project_config = register_project!("proj-get-happy", cached_database_path)

    payload = %{
      "id" => "bead-701",
      "title" => "Ship TRD-012",
      "status" => "open",
      "priority" => 2,
      "dependencies" => ["opaque:dep-1", "dep/2"],
      "assignee" => "operator",
      "description" => "Fetch the issue details",
      "notes" => "Preserve every Issue field",
      "design" => "Map br show payload directly",
      "labels" => ["backend", "get"],
      "metadata" => %{"provider_id" => "beads", "source" => "br show"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-701", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-701", "--json"]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} = BeadsAdapter.get("bead-701", project_config)

    assert issue == %Issue{
             id: "bead-701",
             title: "Ship TRD-012",
             status: "open",
             priority: 2,
             dependencies: ["opaque:dep-1", "dep/2"],
             dependents: [],
             assignee: "operator",
             description: "Fetch the issue details",
             notes: "Preserve every Issue field",
             design: "Map br show payload directly",
             labels: ["backend", "get"],
             metadata: %{"provider_id" => "beads", "source" => "br show"}
           }
  end

  test "dependencies remain opaque ids", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/get/dependencies.db"
    project_config = register_project!("proj-get-dependencies", cached_database_path)

    payload = %{
      "id" => "bead-701b",
      "title" => "Preserve dependency identifiers",
      "status" => "open",
      "priority" => 3,
      "dependencies" => ["opaque:dep-1", "dep/2", "needs-review@3"],
      "assignee" => nil,
      "description" => nil,
      "notes" => "dependencies must stay opaque",
      "design" => nil,
      "labels" => ["blocked"],
      "metadata" => %{"source" => "br show"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-701b", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-701b", "--json"]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} = BeadsAdapter.get("bead-701b", project_config)
    assert issue.dependencies == ["opaque:dep-1", "dep/2", "needs-review@3"]
  end

  test "dependents mapped to [%Issue{}] when payload contains nested issues", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/get/dependents.db"
    project_config = register_project!("proj-get-dependents", cached_database_path)

    payload = %{
      "id" => "bead-701c",
      "title" => "Map nested dependents",
      "status" => "open",
      "priority" => 1,
      "dependencies" => [],
      "dependents" => [%{"id" => "bead-901"}, %{"id" => "bead-902"}],
      "assignee" => nil,
      "description" => "dependents should hydrate as Issue structs",
      "notes" => nil,
      "design" => nil,
      "labels" => ["graph"],
      "metadata" => %{"source" => "br show"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-701c", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-701c", "--json"]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} = BeadsAdapter.get("bead-701c", project_config)
    assert issue.dependencies == []
    assert issue.dependents == [struct(Issue, id: "bead-901"), struct(Issue, id: "bead-902")]
  end

  test "dependencies mapped to [%Issue{}] in get payload", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/get/nested-dependencies.db"
    project_config = register_project!("proj-get-nested-dependencies", cached_database_path)

    payload = %{
      "id" => "bead-701d",
      "title" => "Map nested dependencies",
      "status" => "blocked",
      "priority" => 4,
      "dependencies" => [%{"id" => "bead-901"}, %{"id" => "bead-902"}],
      "dependents" => [],
      "assignee" => "operator",
      "description" => nil,
      "notes" => "dependencies should hydrate as Issue structs",
      "design" => nil,
      "labels" => [],
      "metadata" => %{"source" => "br show"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-701d", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-701d", "--json"]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} = BeadsAdapter.get("bead-701d", project_config)
    assert issue.dependencies == [struct(Issue, id: "bead-901"), struct(Issue, id: "bead-902")]
    assert issue.dependents == []
  end

  test "ISSUE_NOT_FOUND envelope routes through CodeMap with retryable false",
       %{temp_dir: temp_dir} do
    cached_database_path = "/abs/get/error.db"
    project_config = register_project!("proj-get-error", cached_database_path)

    stderr =
      Jason.encode!(%{
        "code" => "ISSUE_NOT_FOUND",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-702", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-702", "--json"]
      )

      {:error, %{stdout: "", stderr: stderr, exit_code: 4}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("bead-702", project_config)

    assert provider_error.code == "ISSUE_NOT_FOUND"
    assert provider_error.retryable? == false
    assert provider_error.message == "Requested issue was not found."
    assert provider_error.hint == "Verify the issue identifier before retrying."
    assert provider_error.context.exit_code == 4
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
    assert provider_error.context.command =~ "br show"
    assert provider_error.context.command =~ "/abs/<redacted:17>"
    refute provider_error.context.command =~ cached_database_path
  end

  test "validation failure returns VALIDATION_FAILED" do
    start_schema_cache!()

    cached_database_path = "/abs/get/validation.db"
    project_config = register_project!("proj-get-validation", cached_database_path)

    expect(BrRunnerMock, :cmd, 1, fn {:show,
                                      %{id: "bead-703", database_path: ^cached_database_path}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => "bead-703",
             "status" => "open",
             "priority" => 1,
             "dependencies" => [],
             "assignee" => nil,
             "description" => nil,
             "notes" => nil,
             "design" => nil,
             "labels" => [],
             "metadata" => %{}
           }),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("bead-703", project_config)

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.command =~ "br show"
    assert provider_error.context.missing_fields == ["title"]
  end

  test "empty task_id returns INVALID_TASK_ID without invoking br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("   ", %{"database_path" => "/abs/path.db"})

    assert provider_error.code == "INVALID_TASK_ID"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "consumes the already-registered absolute database_path verbatim",
       %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path =
      Path.join("/tmp", "beads_test_get_#{System.unique_integer([:positive, :monotonic])}.db")

    assert Path.expand(cached_database_path) == cached_database_path

    project_config = register_project!("proj-get-cached-path", cached_database_path)

    payload = %{
      "id" => "bead-704",
      "title" => "Keep cached path",
      "status" => "blocked",
      "priority" => 0,
      "dependencies" => [],
      "assignee" => nil,
      "description" => nil,
      "notes" => nil,
      "design" => nil,
      "labels" => [],
      "metadata" => %{}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-704", database_path: cached_database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["show", "--db", cached_database_path, "bead-704", "--json"]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{id: "bead-704", status: "blocked", dependents: []}} =
             BeadsAdapter.get("bead-704", project_config)
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
      "required" => [
        "id",
        "title",
        "status",
        "priority",
        "dependencies",
        "dependents",
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
        "dependencies" => %{
          "type" => "array",
          "items" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "required" => ["id"],
                "properties" => %{"id" => %{"type" => "string"}}
              }
            ]
          }
        },
        "dependents" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["id"],
            "properties" => %{"id" => %{"type" => "string"}}
          }
        },
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
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

  defp assert_translated_argv(temp_dir, request, project_config, expected_argv) do
    with_fake_br(
      temp_dir,
      """
      for arg in "$@"; do
        printf '%s\\n' "$arg"
      done
      """,
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd(request, project_config)

        assert String.split(stdout, "\n", trim: true) == expected_argv
      end
    )
  end

  defp write_fake_br!(temp_dir, body) do
    script_path = Path.join(temp_dir, "br")

    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
  end

  defp with_fake_br(temp_dir, body, fun) do
    original_path = System.get_env("PATH") || ""
    write_fake_br!(temp_dir, body)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
