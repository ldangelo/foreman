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
    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

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

    payload =
      issue_details_payload(%{
        "id" => "bead-701",
        "title" => "Ship TRD-012",
        "status" => "open",
        "priority" => 2,
        "dependencies" => [
          nested_issue_payload("bead-901", "D1"),
          nested_issue_payload("bead-902", "D2")
        ],
        "dependents" => [
          nested_issue_payload("bead-903", "D3")
        ],
        "assignee" => "operator",
        "description" => "Fetch the issue details",
        "notes" => "Preserve every Issue field",
        "design" => "Map br show payload directly",
        "labels" => ["backend", "get"],
        "metadata" => %{"provider_id" => "beads", "source" => "br show"}
      })

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

    assert issue ==
             expected_issue("bead-701", "Ship TRD-012",
               status: "open",
               priority: 2,
               dependencies: [
                 expected_issue("bead-901", "D1"),
                 expected_issue("bead-902", "D2")
               ],
               dependents: [
                 expected_issue("bead-903", "D3")
               ],
               assignee: "operator",
               description: "Fetch the issue details",
               notes: "Preserve every Issue field",
               design: "Map br show payload directly",
               labels: ["backend", "get"],
               metadata: %{"provider_id" => "beads", "source" => "br show"}
             )
  end

  test "dependencies are nested Issue objects in get path", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/get/dependencies.db"
    project_config = register_project!("proj-get-dependencies", cached_database_path)

    payload =
      issue_details_payload(%{
        "id" => "bead-701b",
        "title" => "Map nested dependencies",
        "status" => "blocked",
        "priority" => 4,
        "dependencies" => [
          nested_issue_payload("bead-911", "Dependency 1"),
          nested_issue_payload("bead-912", "Dependency 2", %{
            "status" => "blocked",
            "priority" => 3,
            "labels" => ["blocked"],
            "metadata" => %{"source" => "br show"}
          })
        ],
        "dependents" => [],
        "assignee" => "operator",
        "description" => nil,
        "notes" => "dependencies should hydrate as Issue structs",
        "design" => nil,
        "labels" => [],
        "metadata" => %{"source" => "br show"}
      })

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

    assert issue.dependencies == [
             expected_issue("bead-911", "Dependency 1"),
             expected_issue("bead-912", "Dependency 2",
               status: "blocked",
               priority: 3,
               labels: ["blocked"],
               metadata: %{"source" => "br show"}
             )
           ]

    assert issue.dependents == []
  end

  test "dependents mapped to [%Issue{}] when payload contains nested issues", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/get/dependents.db"
    project_config = register_project!("proj-get-dependents", cached_database_path)

    payload =
      issue_details_payload(%{
        "id" => "bead-701c",
        "title" => "Map nested dependents",
        "status" => "open",
        "priority" => 1,
        "dependencies" => [],
        "dependents" => [
          nested_issue_payload("bead-921", "Dependent 1"),
          nested_issue_payload("bead-922", "Dependent 2", %{
            "status" => "blocked",
            "priority" => 2,
            "description" => "nested dependent",
            "labels" => ["graph"]
          })
        ],
        "assignee" => nil,
        "description" => "dependents should hydrate as Issue structs",
        "notes" => nil,
        "design" => nil,
        "labels" => ["graph"],
        "metadata" => %{"source" => "br show"}
      })

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

    assert issue.dependents == [
             expected_issue("bead-921", "Dependent 1"),
             expected_issue("bead-922", "Dependent 2",
               status: "blocked",
               priority: 2,
               description: "nested dependent",
               labels: ["graph"]
             )
           ]
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
             "dependents" => [],
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

  test "schema validation fails when dependencies is missing" do
    start_schema_cache!()

    cached_database_path = "/abs/get/missing-dependencies.db"
    project_config = register_project!("proj-get-missing-dependencies", cached_database_path)

    payload =
      issue_details_payload(%{
        "id" => "bead-703b",
        "title" => "Missing dependencies"
      })
      |> Map.delete("dependencies")

    expect(BrRunnerMock, :cmd, 1, fn {:show,
                                      %{id: "bead-703b", database_path: ^cached_database_path}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("bead-703b", project_config)

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.missing_fields == ["dependencies"]
  end

  test "schema validation fails when dependents is missing" do
    start_schema_cache!()

    cached_database_path = "/abs/get/missing-dependents.db"
    project_config = register_project!("proj-get-missing-dependents", cached_database_path)

    payload =
      issue_details_payload(%{
        "id" => "bead-703c",
        "title" => "Missing dependents"
      })
      |> Map.delete("dependents")

    expect(BrRunnerMock, :cmd, 1, fn {:show,
                                      %{id: "bead-703c", database_path: ^cached_database_path}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("bead-703c", project_config)

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.missing_fields == ["dependents"]
  end

  test "nested dependency with missing id fails with VALIDATION_FAILED" do
    start_schema_cache!()

    cached_database_path = "/abs/get/nested-missing-id.db"
    project_config = register_project!("proj-get-nested-missing-id", cached_database_path)

    payload =
      issue_details_payload(%{
        "id" => "bead-703d",
        "title" => "Nested dependency missing id",
        "dependencies" => [%{}]
      })

    expect(BrRunnerMock, :cmd, 1, fn {:show,
                                      %{id: "bead-703d", database_path: ^cached_database_path}},
                                     ^project_config,
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.get("bead-703d", project_config)

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert "id" in provider_error.context.missing_fields
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

    payload =
      issue_details_payload(%{
        "id" => "bead-704",
        "title" => "Keep cached path",
        "status" => "blocked",
        "priority" => 0
      })

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
    required = issue_details_required_fields()
    properties = issue_details_properties()

    %{
      "$defs" => %{
        "issue" => %{
          "type" => "object",
          "required" => required,
          "properties" => properties
        }
      },
      "type" => "object",
      "required" => required,
      "properties" => properties
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

  defp issue_details_required_fields do
    [
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
    ]
  end

  defp issue_details_properties do
    %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"},
      "dependencies" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/issue"}
      },
      "dependents" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/issue"}
      },
      "assignee" => %{"type" => ["string", "null"]},
      "description" => %{"type" => ["string", "null"]},
      "notes" => %{"type" => ["string", "null"]},
      "design" => %{"type" => ["string", "null"]},
      "labels" => %{"type" => "array"},
      "metadata" => %{"type" => "object"}
    }
  end

  defp issue_details_payload(overrides) do
    Map.merge(
      %{
        "id" => "bead-default",
        "title" => "Default issue",
        "status" => "open",
        "priority" => 1,
        "dependencies" => [],
        "dependents" => [],
        "assignee" => nil,
        "description" => nil,
        "notes" => nil,
        "design" => nil,
        "labels" => [],
        "metadata" => %{}
      },
      overrides
    )
  end

  defp nested_issue_payload(id, title, overrides \\ %{}) do
    issue_details_payload(Map.merge(%{"id" => id, "title" => title}, overrides))
  end

  defp expected_issue(id, title, overrides \\ []) do
    defaults = [
      id: id,
      title: title,
      status: "open",
      priority: 1,
      dependencies: [],
      dependents: [],
      assignee: nil,
      description: nil,
      notes: nil,
      design: nil,
      labels: [],
      metadata: %{}
    ]

    struct!(Issue, Keyword.merge(defaults, overrides))
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
