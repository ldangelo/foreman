defmodule ForemanServer.TaskProviders.BeadsAdapterAddDependencyTest do
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
        "beads_adapter_add_dependency_test_#{System.unique_integer([:positive, :monotonic])}"
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

  test "happy path returns updated Issue with prepended dependency", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/add-dep/happy.db"
    project_config = register_project!("proj-add-dep-happy", cached_database_path)

    payload = %{
      "id" => "bead-701",
      "title" => "Wire dependency edge",
      "status" => "blocked",
      "priority" => 2,
      "dependencies" => ["opaque:dep-1", "opaque:dep-2"],
      "assignee" => "operator",
      "description" => "Preserve all issue fields",
      "notes" => "dependency mutation should be additive",
      "design" => "adapter returns updated issue",
      "labels" => ["backend", "deps"],
      "metadata" => %{"provider_id" => "beads", "source" => "br dep add"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:add_dependency, %{dependent_id: "bead-701", dependency_id: "opaque:dep-9"}}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["dep", "add", "bead-701", "opaque:dep-9", "--json", "--db", cached_database_path]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} =
             BeadsAdapter.add_dependency("bead-701", "opaque:dep-9", project_config)

    assert issue == %Issue{
             id: "bead-701",
             title: "Wire dependency edge",
             status: "blocked",
             priority: 2,
             dependencies: ["opaque:dep-9", "opaque:dep-1", "opaque:dep-2"],
             assignee: "operator",
             description: "Preserve all issue fields",
             notes: "dependency mutation should be additive",
             design: "adapter returns updated issue",
             labels: ["backend", "deps"],
             metadata: %{"provider_id" => "beads", "source" => "br dep add"}
           }
  end

  test "exact br dep add argv shape is preserved and success prepends the new dependency", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/add-dep/argv.db"
    project_config = register_project!("proj-add-dep-argv", cached_database_path)

    payload = %{
      "id" => "bead-707",
      "title" => "Preserve argv order",
      "status" => "blocked",
      "priority" => 3,
      "dependencies" => ["opaque:dep-4", "opaque:dep-2"],
      "assignee" => nil,
      "description" => nil,
      "notes" => nil,
      "design" => nil,
      "labels" => [],
      "metadata" => %{}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:add_dependency, %{dependent_id: "bead-707", dependency_id: "opaque:dep-4"}}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["dep", "add", "bead-707", "opaque:dep-4", "--json", "--db", cached_database_path]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{dependencies: ["opaque:dep-4", "opaque:dep-2"]}} =
             BeadsAdapter.add_dependency("bead-707", "opaque:dep-4", project_config)
  end

  test "br error envelope returns mapped ProviderError", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/add-dep/error.db"
    project_config = register_project!("proj-add-dep-error", cached_database_path)

    stderr =
      Jason.encode!(%{
        "code" => "DEPENDENCY_EXISTS",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:add_dependency, %{dependent_id: "bead-702", dependency_id: "opaque:dep-5"}}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["dep", "add", "bead-702", "opaque:dep-5", "--json", "--db", cached_database_path]
      )

      {:error, %{stdout: "", stderr: stderr, exit_code: 5}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.add_dependency("bead-702", "opaque:dep-5", project_config)

    assert provider_error.code == "DEPENDENCY_EXISTS"
    assert provider_error.retryable? == false
    assert provider_error.context.command == "br dep add"
    assert provider_error.context.exit_code == 5
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
  end

  test "validation failure returns VALIDATION_FAILED", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/add-dep/validation.db"
    project_config = register_project!("proj-add-dep-validation", cached_database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:add_dependency, %{dependent_id: "bead-703", dependency_id: "opaque:dep-3"}}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["dep", "add", "bead-703", "opaque:dep-3", "--json", "--db", cached_database_path]
      )

      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => "bead-703",
             "status" => "blocked",
             "priority" => 1,
             "dependencies" => ["opaque:dep-3"],
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
             BeadsAdapter.add_dependency("bead-703", "opaque:dep-3", project_config)

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.command == "br dep add"
    assert provider_error.context.missing_fields == ["title"]
  end

  test "self dependency returns DEPENDENCY_CYCLE without invoking br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.add_dependency("bead-704", "bead-704", %{
               "database_path" => "/abs/path.db"
             })

    assert provider_error.code == "DEPENDENCY_CYCLE"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "empty ids return INVALID_TASK_ID without invoking br" do
    assert {:error, %ProviderError{} = dependent_error} =
             BeadsAdapter.add_dependency("   ", "opaque:dep-7", %{
               "database_path" => "/abs/path.db"
             })

    assert dependent_error.code == "INVALID_TASK_ID"
    assert dependent_error.context.command == nil
    assert dependent_error.context.stderr_byte_count == 0

    assert {:error, %ProviderError{} = dependency_error} =
             BeadsAdapter.add_dependency("bead-705", "", %{
               "database_path" => "/abs/path.db"
             })

    assert dependency_error.code == "INVALID_TASK_ID"
    assert dependency_error.context.command == nil
    assert dependency_error.context.stderr_byte_count == 0
  end

  test "dependency id outside id_format returns INVALID_TASK_ID before argv construction" do
    assert %{id_format: id_format} = BeadsAdapter.capabilities()
    refute Regex.match?(Regex.compile!(id_format), "bad dep")

    expect(BrRunnerMock, :cmd, 0, fn request, project_config, opts ->
      flunk(
        "BrRunnerMock.cmd/3 must not be invoked for invalid dependency id format: " <>
          inspect({request, project_config, opts})
      )
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.add_dependency("bead-705", "bad dep", %{
               "database_path" => "/abs/path.db"
             })

    assert provider_error.code == "INVALID_TASK_ID"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "consumes the cached absolute database_path established at registration verbatim", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/cached/../add-dep/path.db"
    project_config = register_project!("proj-add-dep-cached-path", cached_database_path)

    payload = %{
      "id" => "bead-706",
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
      assert request ==
               {:add_dependency, %{dependent_id: "bead-706", dependency_id: "opaque:dep-8"}}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["dep", "add", "bead-706", "opaque:dep-8", "--json", "--db", cached_database_path]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{id: "bead-706", dependencies: ["opaque:dep-8"], status: "blocked"}} =
             BeadsAdapter.add_dependency("bead-706", "opaque:dep-8", project_config)
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
