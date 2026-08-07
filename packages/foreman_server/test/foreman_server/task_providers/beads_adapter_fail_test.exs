defmodule ForemanServer.TaskProviders.BeadsAdapterFailTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemBrRunner

  @cache_name :foreman_server_json_schema_cache
  @fail_success_event [:foreman_server, :task_provider, :beads_adapter, :fail, :success]
  @rejected_event [:foreman_server, :task_provider, :transition_comment, :rejected]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
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
        "beads_adapter_fail_test_#{System.unique_integer([:positive, :monotonic])}"
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

  test "happy path returns {:ok, %Issue{status: \"open\"}} and emits success telemetry", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    handler_id = attach_handler(@fail_success_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    cached_database_path = "/abs/fail/happy.db"
    project_config = register_project!("proj-fail-happy", cached_database_path)

    payload = %{
      "id" => "bead-901",
      "title" => "Reopen after failure",
      "description" => "Worker failed; reopen task",
      "priority" => 2,
      "dependencies" => ["opaque:dep-1"],
      "assignee" => "operator",
      "notes" => "preserve transition context outside Issue",
      "design" => "adapter should return an open issue",
      "labels" => ["backend", "fail"],
      "metadata" => %{"provider_id" => "beads", "source" => "br update"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-901",
                    "--status",
                    "open",
                    "--transition-comment",
                    "operator-comment"
                  ],
                  database_path: cached_database_path
                }}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          cached_database_path,
          "bead-901",
          "--status",
          "open",
          "--transition-comment",
          "operator-comment",
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Issue{} = issue} =
             BeadsAdapter.fail(
               "bead-901",
               %{transition_comment: "operator-comment", run_id: "run-901"},
               project_config
             )

    assert issue.status == "open"
    assert issue.id == "bead-901"
    assert issue.title == "Reopen after failure"

    assert_receive {:telemetry, @fail_success_event, %{system_time: _}, %{argv: argv}}, 1_000

    assert argv == [
             "update",
             "--db",
             redacted_database_path(cached_database_path),
             "bead-901",
             "--status",
             "open",
             "--transition-comment",
             "operator-comment",
             "--json"
           ]
  end

  test "fabricates deterministic transition_comment when operator comment is absent", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/fail/fabricated.db"
    project_config = register_project!("proj-fail-fabricated", cached_database_path)
    artifact_path = "/artifacts/run-902/failure.md"
    fabricated_comment = "foreman-run:run-902:#{artifact_path}"

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-902",
                    "--status",
                    "open",
                    "--transition-comment",
                    fabricated_comment
                  ],
                  database_path: cached_database_path
                }}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          cached_database_path,
          "bead-902",
          "--status",
          "open",
          "--transition-comment",
          fabricated_comment,
          "--json"
        ]
      )

      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => "bead-902",
             "description" => "Reopened after failure",
             "metadata" => %{"provider_id" => "beads"}
           }),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{id: "bead-902", status: "open", title: "bead-902"}} =
             BeadsAdapter.fail(
               "bead-902",
               %{run_id: "run-902", artifact_path: artifact_path},
               project_config
             )
  end

  test "unknown br.code fallback emits telemetry, logs scrubbed argv, and returns BR_ERROR_ENVELOPE",
       %{
         temp_dir: temp_dir
       } do
    start_schema_cache!()

    handler_id = attach_handler(@rejected_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    cached_database_path = "/abs/fail/unknown.db"
    project_config = register_project!("proj-fail-unknown", cached_database_path)

    artifact_path =
      "/very/long/artifacts/with/sensitive/context/that/forces/transition/comment/redaction/failure.md"

    fabricated_comment = "foreman-run:run-903:#{artifact_path}"

    stderr =
      Jason.encode!(%{
        "code" => "UNKNOWN_BR_CODE",
        "message" => "raw envelope message",
        "hint" => "raw envelope hint",
        "retryable?" => true
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-903",
                    "--status",
                    "open",
                    "--transition-comment",
                    fabricated_comment
                  ],
                  database_path: cached_database_path
                }}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          cached_database_path,
          "bead-903",
          "--status",
          "open",
          "--transition-comment",
          fabricated_comment,
          "--json"
        ]
      )

      {:error, %{stdout: "", stderr: stderr, exit_code: 7}}
    end)

    log =
      capture_log(fn ->
        assert {:error, %ProviderError{} = provider_error} =
                 BeadsAdapter.fail(
                   "bead-903",
                   %{run_id: "run-903", artifact_path: artifact_path},
                   project_config
                 )

        assert provider_error.code == "BR_ERROR_ENVELOPE"
        assert provider_error.message == "UNKNOWN_BR_CODE"
        assert provider_error.hint == nil
        assert provider_error.retryable? == true
        assert provider_error.context.command =~ redacted_database_path(cached_database_path)
        assert provider_error.context.command =~ "<redacted:64>"
        refute provider_error.context.command =~ cached_database_path
        refute provider_error.context.command =~ artifact_path
      end)

    assert_receive {:telemetry, @rejected_event, %{system_time: _}, metadata}, 1_000

    assert metadata.raw_code == "UNKNOWN_BR_CODE"
    assert metadata.task_id == "bead-903"

    assert metadata.argv == [
             "update",
             "--db",
             redacted_database_path(cached_database_path),
             "bead-903",
             "--status",
             "open",
             "--transition-comment",
             "<redacted:64>",
             "--json"
           ]

    assert log =~ "BR_ERROR_ENVELOPE"
    assert log =~ "UNKNOWN_BR_CODE"
    assert log =~ redacted_database_path(cached_database_path)
    assert log =~ "<redacted:64>"
    refute log =~ "raw envelope message"
    refute log =~ "raw envelope hint"
    refute log =~ artifact_path
  end

  test "validation failure returns VALIDATION_FAILED", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/fail/validation.db"
    project_config = register_project!("proj-fail-validation", cached_database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: ["bead-904", "--status", "open", "--transition-comment", "schema-check"],
                  database_path: cached_database_path
                }}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          cached_database_path,
          "bead-904",
          "--status",
          "open",
          "--transition-comment",
          "schema-check",
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(%{"id" => "bead-904"}), stderr: "", exit_code: 0}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.fail(
               "bead-904",
               %{transition_comment: "schema-check", run_id: "run-904"},
               project_config
             )

    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false
    assert provider_error.context.command =~ redacted_database_path(cached_database_path)
    assert provider_error.context.missing_fields == ["description"]
  end

  test "empty task_id returns INVALID_TASK_ID without invoking br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.fail("   ", %{transition_comment: "ignored"}, %{
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

    cached_database_path = "/abs/cached/../fail/path.db"
    project_config = register_project!("proj-fail-cached-path", cached_database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: ["bead-905", "--status", "open", "--transition-comment", "cached-path"],
                  database_path: cached_database_path
                }}

      assert runner_project_config == %{database_path: cached_database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          cached_database_path,
          "bead-905",
          "--status",
          "open",
          "--transition-comment",
          "cached-path",
          "--json"
        ]
      )

      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => "bead-905",
             "description" => "Keep cached path",
             "metadata" => %{}
           }),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{id: "bead-905", status: "open"}} =
             BeadsAdapter.fail(
               "bead-905",
               %{transition_comment: "cached-path", run_id: "run-905"},
               project_config
             )
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

  defp attach_handler(event) do
    handler_id = "beads-adapter-fail-test-#{System.unique_integer([:positive, :monotonic])}"
    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, self())
    handler_id
  end

  def handle_telemetry(telemetry_event, measurements, metadata, pid) do
    send(pid, {:telemetry, telemetry_event, measurements, metadata})
  end

  defp redacted_database_path(database_path) do
    "/abs/<redacted:#{String.length(database_path)}>"
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
