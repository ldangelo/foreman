defmodule ForemanServer.CLI.DoctorTaskProviderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias ForemanServer.CLI
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.{BeadsAdapter, BrRunnerMock}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @cache_name :foreman_server_json_schema_cache
  @project_prefix "doctor-task-provider-"
  @missing_database_stderr ~s({"code":"DATABASE_NOT_FOUND","message":"super secret raw stderr","hint":"super secret raw hint","retryable?":true})

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)

    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: "foreman-runner",
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [BeadsAdapter]
    )

    reset_projection_store_state()
    stop_schema_cache()
    restart_registry()

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "doctor_task_provider_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)

    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
      System.put_env("PATH", original_path)
      stop_schema_cache()
      reset_projection_store_state()
    end)

    {:ok, temp_dir: temp_dir, original_path: original_path}
  end

  test "CLI.run/1 returns usage for incomplete doctor command" do
    assert {:error, 64, "usage: foreman doctor task_provider"} = CLI.run(["doctor"])
  end

  test "doctor task_provider reports a healthy project with a clean snapshot", %{
    temp_dir: temp_dir,
    original_path: original_path
  } do
    project_id = unique_project_id("healthy")
    database_path = unique_database_path("healthy")
    ready_issue = ready_issue_payload(%{"id" => "ready-1", "title" => "Ready issue"})
    capabilities_payload = %{"commands" => [%{"name" => "ready"}, %{"name" => "show"}]}

    seed_project!(project_id, project_task_provider(database_path))
    put_fake_br_on_path!(temp_dir, original_path)

    assert :ok =
             TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => database_path
             })

    expect_schema_boot_fetches()

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: ^database_path}},
                                     %{database_path: ^database_path},
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{stdout: Jason.encode!(%{"database_path" => database_path}), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:version, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: "br 1.2.3\n", stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:capabilities, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(capabilities_payload), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{flags: ["--limit", "1"]}},
                                     %{"database_path" => ^database_path},
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!([ready_issue]), stderr: "", exit_code: 0}}
    end)

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["doctor", "task_provider"])
      end)

    report = decode_single_report(output)

    assert report["project_id"] == project_id
    assert report["healthy"] == true
    assert report["provider_id"] == "beads"
    assert report["contract_version"] == "br.capabilities.v1"
    assert report["br_version"] == "br 1.2.3"
    assert report["capabilities"] == capabilities_payload
    assert report["sample_ready"] == [ready_issue]
    assert report["schema_validation_failures"] == []
    refute Map.has_key?(report, "error")
  end

  test "doctor task_provider surfaces DATABASE_NOT_FOUND without raw stderr", %{
    temp_dir: temp_dir,
    original_path: original_path
  } do
    project_id = unique_project_id("missing-db")
    database_path = unique_database_path("missing-db")

    seed_project!(project_id, project_task_provider(database_path))
    put_fake_br_on_path!(temp_dir, original_path)

    expect_schema_boot_fetches()

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: ^database_path}},
                                     %{database_path: ^database_path},
                                     [timeout_ms: 30_000] ->
      {:error, %{stdout: "", stderr: @missing_database_stderr, exit_code: 2}}
    end)

    output =
      capture_io(fn ->
        assert {:error, 1, "one or more unhealthy task_provider projects"} =
                 CLI.run(["doctor", "task_provider"])
      end)

    report = decode_single_report(output)
    error = report["error"]

    assert report["project_id"] == project_id
    assert report["healthy"] == false
    assert error["code"] == "DATABASE_NOT_FOUND"
    assert error["stderr_byte_count"] == byte_size(@missing_database_stderr)
    assert error["redacted_fields"] == []
    refute Map.has_key?(error, "sanitized_stderr_excerpt")
    refute output =~ "super secret raw stderr"
    refute output =~ "super secret raw hint"
    refute output =~ @missing_database_stderr
  end

  test "doctor task_provider reports provider missing when br is unavailable" do
    project_id = unique_project_id("provider-missing")
    database_path = unique_database_path("provider-missing")

    missing_path =
      Path.join(System.tmp_dir!(), "missing-br-#{System.unique_integer([:positive, :monotonic])}")

    seed_project!(project_id, project_task_provider(database_path))
    System.put_env("PATH", missing_path)

    refute BeadsAdapter.available?()

    expect_schema_boot_fetches()

    output =
      capture_io(fn ->
        assert {:error, 1, "one or more unhealthy task_provider projects"} =
                 CLI.run(["doctor", "task_provider"])
      end)

    report = decode_single_report(output)
    error = report["error"]

    assert report["project_id"] == project_id
    assert report["healthy"] == false
    assert error["code"] == "PROVIDER_MISSING"
    assert error["message"] == "br not installed"
    assert error["stderr_byte_count"] == 0
    assert error["redacted_fields"] == []
  end

  test "doctor task_provider reports each project independently", %{
    temp_dir: temp_dir,
    original_path: original_path
  } do
    healthy_project_id = unique_project_id("multi-a-healthy")
    healthy_database_path = unique_database_path("multi-a-healthy")
    ready_issue = ready_issue_payload(%{"id" => "ready-multi", "title" => "Multi issue"})
    capabilities_payload = %{"commands" => [%{"name" => "ready"}]}
    unhealthy_project_id = unique_project_id("multi-b-unhealthy")
    unhealthy_database_path = unique_database_path("multi-b-unhealthy")

    seed_project!(healthy_project_id, project_task_provider(healthy_database_path))
    seed_project!(unhealthy_project_id, project_task_provider(unhealthy_database_path))
    put_fake_br_on_path!(temp_dir, original_path)

    assert :ok =
             TaskProviderRegistry.register_for_project(healthy_project_id, BeadsAdapter, %{
               "database_path" => healthy_database_path
             })

    assert :ok =
             TaskProviderRegistry.register_for_project(unhealthy_project_id, BeadsAdapter, %{
               "database_path" => unhealthy_database_path
             })

    expect_schema_boot_fetches()

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: ^healthy_database_path}},
                                     %{database_path: ^healthy_database_path},
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout: Jason.encode!(%{"database_path" => healthy_database_path}),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:version, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: "br 1.2.3\n", stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:capabilities, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(capabilities_payload), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{flags: ["--limit", "1"]}},
                                     %{"database_path" => ^healthy_database_path},
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!([ready_issue]), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: ^unhealthy_database_path}},
                                     %{database_path: ^unhealthy_database_path},
                                     [timeout_ms: 30_000] ->
      {:error, %{stdout: "", stderr: @missing_database_stderr, exit_code: 2}}
    end)

    output =
      capture_io(fn ->
        assert {:error, 1, "one or more unhealthy task_provider projects"} =
                 CLI.run(["doctor", "task_provider"])
      end)

    reports =
      output
      |> decode_reports()
      |> Map.new(fn report -> {report["project_id"], report} end)

    healthy_report = Map.fetch!(reports, healthy_project_id)
    unhealthy_report = Map.fetch!(reports, unhealthy_project_id)

    assert map_size(reports) == 2

    assert healthy_report["healthy"] == true
    assert healthy_report["sample_ready"] == [ready_issue]
    assert healthy_report["capabilities"] == capabilities_payload
    refute Map.has_key?(healthy_report, "error")

    assert unhealthy_report["healthy"] == false
    assert unhealthy_report["error"]["code"] == "DATABASE_NOT_FOUND"
    assert unhealthy_report["error"]["stderr_byte_count"] == byte_size(@missing_database_stderr)
    assert unhealthy_report["error"]["redacted_fields"] == []
    refute output =~ "super secret raw stderr"
  end

  test "doctor task_provider marks schema validation failures unhealthy", %{
    temp_dir: temp_dir,
    original_path: original_path
  } do
    project_id = unique_project_id("schema-failure")
    database_path = unique_database_path("schema-failure")
    capabilities_payload = %{"commands" => [%{"name" => "ready"}]}

    seed_project!(project_id, project_task_provider(database_path))
    put_fake_br_on_path!(temp_dir, original_path)

    assert :ok =
             TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => database_path
             })

    expect_schema_boot_fetches()

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: ^database_path}},
                                     %{database_path: ^database_path},
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{stdout: Jason.encode!(%{"database_path" => database_path}), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:version, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: "br 1.2.3\n", stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:capabilities, %{}}, %{}, [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!(capabilities_payload), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:ready, %{flags: ["--limit", "1"]}},
                                     %{"database_path" => ^database_path},
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: Jason.encode!([%{"id" => "ready-1"}]), stderr: "", exit_code: 0}}
    end)

    output =
      capture_io(fn ->
        assert {:error, 1, "one or more unhealthy task_provider projects"} =
                 CLI.run(["doctor", "task_provider"])
      end)

    report = decode_single_report(output)
    [failure | _] = report["schema_validation_failures"]

    assert report["project_id"] == project_id
    assert report["healthy"] == false
    assert report["sample_ready"] == [%{"id" => "ready-1"}]
    assert failure["probe"] == "ready"
    assert failure["schema"] == "ready_issue"
    refute Map.has_key?(report, "error")
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end

  defp restart_registry do
    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)
  end

  defp seed_project!(project_id, task_provider) do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: project_id,
                   path: System.tmp_dir!(),
                   task_provider: task_provider
                 }
               }
             ])
  end

  defp reset_projection_store_state do
    ProjectionStoreReset.reset!()
  end

  defp expect_schema_boot_fetches do
    expect(BrRunnerMock, :cmd, 4, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name)), stderr: "", exit_code: 0}}
    end)
  end

  defp put_fake_br_on_path!(temp_dir, original_path) do
    write_fake_br!(temp_dir, "printf 'br\\n'")
    System.put_env("PATH", temp_dir <> ":" <> original_path)
  end

  defp write_fake_br!(temp_dir, body) do
    script_path = Path.join(temp_dir, "br")
    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp decode_reports(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&(String.starts_with?(&1, "{") and String.contains?(&1, "\"project_id\"")))
    |> Enum.map(&Jason.decode!/1)
  end

  defp decode_single_report(output) do
    reports = decode_reports(output)

    assert length(reports) == 1
    hd(reports)
  end

  defp unique_project_id(label) do
    "#{@project_prefix}#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_database_path(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{label}-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    File.touch!(path)
    path
  end

  defp project_task_provider(database_path) do
    %{
      provider: BeadsAdapter,
      config: %{"database_path" => database_path}
    }
  end

  defp ready_issue_payload(overrides) do
    Map.merge(
      %{
        "id" => "ready-default",
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
end
