defmodule ForemanServer.TaskProviders.BeadsAdapterReopenTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
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
        "beads_adapter_reopen_test_#{System.unique_integer([:positive, :monotonic])}"
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

  test "happy path returns {:ok, %Issue{status: \"open\"}} and includes the supplied transition_comment",
       %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/reopen/happy.db"
    project_config = register_project!("proj-reopen-happy", cached_database_path)
    transition_comment = "foreman-run-reconciled"

    payload = %{
      "id" => "bead-1001",
      "title" => "Reopen TRD-016",
      "status" => "blocked",
      "priority" => 1,
      "dependencies" => ["opaque:dep-1"],
      "assignee" => nil,
      "description" => "Task returned to ready state",
      "notes" => "reopened by operator",
      "design" => "adapter should return open issue",
      "labels" => ["backend", "reopen"],
      "metadata" => %{"provider_id" => "beads", "source" => "br update"}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-1001",
                    "--status",
                    "open",
                    "--transition-comment",
                    transition_comment
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
          "bead-1001",
          "--status",
          "open",
          "--transition-comment",
          transition_comment,
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, issue} = BeadsAdapter.reopen("bead-1001", transition_comment, project_config)
    assert is_struct(issue, Issue)

    assert issue == %Issue{
             id: "bead-1001",
             title: "Reopen TRD-016",
             status: "open",
             priority: 1,
             dependencies: ["opaque:dep-1"],
             dependents: [],
             assignee: nil,
             description: "Task returned to ready state",
             notes: "reopened by operator",
             design: "adapter should return open issue",
             labels: ["backend", "reopen"],
             metadata: %{"provider_id" => "beads", "source" => "br update"}
           }
  end

  test "ISSUE_NOT_FOUND envelopes route through CodeMap to ProviderError" do
    start_schema_cache!()

    cached_database_path = "/abs/reopen/error.db"
    project_config = register_project!("proj-reopen-error", cached_database_path)
    transition_comment = "missing-issue"

    stderr =
      Jason.encode!(%{
        "code" => "ISSUE_NOT_FOUND",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn {:update,
                                      %{
                                        flags: [
                                          "bead-1002",
                                          "--status",
                                          "open",
                                          "--transition-comment",
                                          ^transition_comment
                                        ],
                                        database_path: ^cached_database_path
                                      }},
                                     %{database_path: ^cached_database_path},
                                     [timeout_ms: 30_000] ->
      {:error, %{stdout: "", stderr: stderr, exit_code: 3}}
    end)

    assert {:error, provider_error} =
             BeadsAdapter.reopen("bead-1002", transition_comment, project_config)

    assert is_struct(provider_error, ProviderError)
    assert provider_error.code == "ISSUE_NOT_FOUND"
    assert provider_error.retryable? == false
    assert provider_error.message == "Requested issue was not found."
    assert provider_error.hint == "Verify the issue identifier before retrying."

    assert provider_error.context.command ==
             "br update --db #{redacted_database_path(cached_database_path)} bead-1002 --status open --transition-comment missing-issue --json"

    assert provider_error.context.exit_code == 3
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
  end

  test "validation failure returns VALIDATION_FAILED", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/reopen/validation.db"
    project_config = register_project!("proj-reopen-validation", cached_database_path)
    transition_comment = "schema-check"

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-1003",
                    "--status",
                    "open",
                    "--transition-comment",
                    transition_comment
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
          "bead-1003",
          "--status",
          "open",
          "--transition-comment",
          transition_comment,
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(%{"id" => "bead-1003"}), stderr: "", exit_code: 0}}
    end)

    assert {:error, provider_error} =
             BeadsAdapter.reopen("bead-1003", transition_comment, project_config)

    assert is_struct(provider_error, ProviderError)
    assert provider_error.code == "VALIDATION_FAILED"
    assert provider_error.retryable? == false

    assert provider_error.context.command ==
             "br update --db #{redacted_database_path(cached_database_path)} bead-1003 --status open --transition-comment schema-check --json"

    assert provider_error.context.missing_fields == ["description"]
  end

  test "ALREADY_OPEN returns {:ok, :already_terminal}", %{temp_dir: temp_dir} do
    start_schema_cache!()

    cached_database_path = "/abs/reopen/already-open.db"
    project_config = register_project!("proj-reopen-already-open", cached_database_path)
    transition_comment = "already-open-comment"

    stderr =
      Jason.encode!(%{
        "code" => "ALREADY_OPEN",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-1004",
                    "--status",
                    "open",
                    "--transition-comment",
                    transition_comment
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
          "bead-1004",
          "--status",
          "open",
          "--transition-comment",
          transition_comment,
          "--json"
        ]
      )

      {:error, %{stdout: "", stderr: stderr, exit_code: 9}}
    end)

    assert {:ok, :already_terminal} =
             BeadsAdapter.reopen("bead-1004", transition_comment, project_config)
  end

  test "ALREADY_OPEN CodeMap translation remains non-retryable" do
    provider_error =
      %{
        "code" => "ALREADY_OPEN",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => true
      }
      |> ProviderErrorInput.from_br_envelope()
      |> CodeMap.build_provider_error("br update --transition-comment foreman-run-reconciled", 11)

    assert provider_error.code == "ALREADY_TERMINAL"
    assert provider_error.retryable? == false
    assert provider_error.message == "Issue is already closed."
    assert provider_error.hint == "Treat duplicate completion as an idempotent success."

    assert provider_error.context.command ==
             "br update --transition-comment foreman-run-reconciled"

    assert provider_error.context.stderr_byte_count == 11
  end

  test "empty task_id returns INVALID_TASK_ID without invoking br" do
    assert {:error, provider_error} =
             BeadsAdapter.reopen("", :ignored, %{"database_path" => "/abs/path.db"})

    assert is_struct(provider_error, ProviderError)
    assert provider_error.code == "INVALID_TASK_ID"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "blank transition_comment returns INVALID_TRANSITION_COMMENT without invoking br" do
    assert {:error, provider_error} =
             BeadsAdapter.reopen("bead-blank-comment", "", %{"database_path" => "/abs/path.db"})

    assert is_struct(provider_error, ProviderError)
    assert provider_error.code == "INVALID_TRANSITION_COMMENT"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "consumes the cached absolute database_path established at registration verbatim", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    cached_database_path = "/abs/cached/../reopen/path.db"
    project_config = register_project!("proj-reopen-cached-path", cached_database_path)
    transition_comment = "cached-path"

    payload = %{
      "id" => "bead-1005",
      "description" => "Keep cached path verbatim",
      "metadata" => %{}
    }

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-1005",
                    "--status",
                    "open",
                    "--transition-comment",
                    transition_comment
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
          "bead-1005",
          "--status",
          "open",
          "--transition-comment",
          transition_comment,
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
    end)

    assert {:ok, issue} = BeadsAdapter.reopen("bead-1005", transition_comment, project_config)
    assert is_struct(issue, Issue)
    assert issue.id == "bead-1005"
    assert issue.status == "open"
    assert issue.description == "Keep cached path verbatim"
    assert issue.dependents == []
  end

  test "lib scan finds zero in-tree BeadsAdapter.reopen callers on this branch" do
    assert enumerate_beads_adapter_reopen_callers() == []
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

  defp enumerate_beads_adapter_reopen_callers do
    lib_root = Path.join(package_root(), "lib")
    {output, exit_code} = System.cmd("grep", ["-R", "-nF", "BeadsAdapter.reopen(", lib_root])

    case exit_code do
      0 ->
        String.split(output, "\n", trim: true)

      1 ->
        []

      other ->
        flunk(
          "grep failed while scanning lib/ for BeadsAdapter.reopen callers: #{inspect(other)}"
        )
    end
  end

  defp package_root do
    Path.expand("../../..", __DIR__)
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
