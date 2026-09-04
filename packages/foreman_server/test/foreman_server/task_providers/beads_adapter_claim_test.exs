defmodule ForemanServer.TaskProviders.BeadsAdapterClaimTest do
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
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
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
        "beads_adapter_claim_test_#{System.unique_integer([:positive, :monotonic])}"
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

  test "claim/3 returns an in_progress Issue with the actor as assignee", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/path"
    project_config = register_project!("proj-claim-success", cached_database_path)
    project_config = Map.put(project_config, "run_id", "run-claim-success")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-101"]}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", cached_database_path, "--claim", "bead-101", "--json"]
      )

      {:ok,
       %{
         stdout: Jason.encode!(issue_payload(%{"status" => "in_progress"})),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{} = issue} =
             BeadsAdapter.claim("bead-101", "foreman-actor", project_config)

    assert issue == %Issue{
             id: "bead-101",
             title: "Claim TRD-013",
             status: "in_progress",
             priority: 2,
             dependencies: ["dep-1"],
             dependents: [],
             assignee: "foreman-actor",
             description: "Claimed issue payload",
             notes: "Keep cached paths verbatim",
             design: "Map to Issue struct",
             labels: ["backend", "claim"],
             metadata: %{"provider_id" => "beads", "source" => "br update"}
           }
  end

  test "claim/3 unwraps JSON array returned by `br update --claim` (current CLI contract)" do
    start_schema_cache!()

    cached_database_path = "/abs/path"
    project_config = register_project!("proj-claim-array", cached_database_path)
    project_config = Map.put(project_config, "run_id", "run-claim-array")

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", "bead-101"]}}

      {:ok,
       %{
         stdout: Jason.encode!([issue_payload(%{"status" => "in_progress"})]),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{} = issue} =
             BeadsAdapter.claim("bead-101", "foreman-actor", project_config)

    assert issue.id == "bead-101"
    assert issue.assignee == "foreman-actor"
    assert issue.status == "in_progress"
  end

  test "claim/3 routes NOT_CLAIMABLE through CodeMap as non-retryable", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/path"
    project_config = register_project!("proj-claim-not-claimable", cached_database_path)
    project_config = Map.put(project_config, "run_id", "run-claim-not-claimable")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-102"]}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", cached_database_path, "--claim", "bead-102", "--json"]
      )

      {:error,
       %{
         stdout: "",
         stderr:
           Jason.encode!(%{
             "code" => "NOT_CLAIMABLE",
             "message" => "original message",
             "hint" => "original hint",
             "retryable?" => false
           }),
         exit_code: 2
       }}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.claim("bead-102", "foreman-actor", project_config)

    assert provider_error.code == "NOT_CLAIMABLE"
    assert provider_error.retryable? == false
    assert provider_error.context.command == "br update"
    assert provider_error.context.exit_code == 2
  end

  test "claim/3 routes CLAIMED_BY_OTHER without exposing the assignee value",
       %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/path"
    project_config = register_project!("proj-claim-claimed-by-other", cached_database_path)
    project_config = Map.put(project_config, "run_id", "run-claim-claimed-by-other")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-102b"]}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", cached_database_path, "--claim", "bead-102b", "--json"]
      )

      {:error,
       %{
         stdout: "",
         stderr:
           Jason.encode!(%{
             "code" => "CLAIMED_BY_OTHER",
             "message" => "original message",
             "hint" => "original hint",
             "retryable?" => true,
             "current_assignee" => "secret-owner"
           }),
         exit_code: 3
       }}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.claim("bead-102b", "foreman-actor", project_config)

    assert provider_error.code == "CLAIMED_BY_OTHER"
    assert provider_error.retryable? == true
    assert provider_error.context.current_assignee_present? == true
    assert "current_assignee" in provider_error.context.redacted_fields
    refute Map.has_key?(provider_error.context, :current_assignee)
    refute inspect(provider_error) =~ "secret-owner"
  end

  test "claim/3 returns SCHEMA_VALIDATION_FAILED when the claimed issue payload is malformed",
       %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/path"
    project_config = register_project!("proj-claim-schema-validation", cached_database_path)
    project_config = Map.put(project_config, "run_id", "run-claim-schema-validation")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-103"]}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", cached_database_path, "--claim", "bead-103", "--json"]
      )

      {:ok,
       %{
         stdout: Jason.encode!(%{"id" => "bead-103", "status" => "in_progress"}),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.claim("bead-103", "foreman-actor", project_config)

    assert provider_error.code == "SCHEMA_VALIDATION_FAILED"
    assert provider_error.context.command == "br update"
    assert "title" in provider_error.context.missing_fields
  end

  test "claim/3 returns INVALID_TASK_ID without calling br for empty task ids" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.claim("   ", "foreman-actor", %{"database_path" => "/abs/path"})

    assert provider_error.code == "INVALID_TASK_ID"
    assert provider_error.retryable? == false
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

  defp issue_payload(overrides) do
    Map.merge(
      %{
        "id" => "bead-101",
        "title" => "Claim TRD-013",
        "status" => "in_progress",
        "priority" => 2,
        "dependencies" => ["dep-1"],
        "assignee" => "beads-user",
        "description" => "Claimed issue payload",
        "notes" => "Keep cached paths verbatim",
        "design" => "Map to Issue struct",
        "labels" => ["backend", "claim"],
        "metadata" => %{"provider_id" => "beads", "source" => "br update"}
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
