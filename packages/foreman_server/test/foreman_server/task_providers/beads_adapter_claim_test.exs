defmodule ForemanServer.TaskProviders.BeadsAdapterClaimTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache

  @cache_name :foreman_server_json_schema_cache

  setup_all do
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stop_schema_cache()

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    on_exit(&stop_schema_cache/0)

    :ok
  end

  test "claim/3 returns an in_progress Issue on success" do
    start_schema_cache!()

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-101"]}}
      assert project_config == %{database_path: "/abs/path"}
      assert opts == [timeout_ms: 30_000]

      {:ok,
       %{
         stdout: Jason.encode!(issue_payload(%{"status" => "in_progress"})),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{} = issue} =
             BeadsAdapter.claim("bead-101", "foreman-actor", %{database_path: "/abs/path"})

    assert issue.status == "in_progress"
    assert issue.assignee == "foreman-actor"
    assert issue.id == "bead-101"
  end

  test "claim/3 routes NOT_CLAIMABLE through CodeMap as non-retryable" do
    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", "bead-102"]}},
                                     %{database_path: "/abs/path"},
                                     [timeout_ms: 30_000] ->
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

    assert {:error, %{code: "NOT_CLAIMABLE"} = provider_error} =
             BeadsAdapter.claim("bead-102", "foreman-actor", %{database_path: "/abs/path"})

    assert provider_error.retryable? == false
    assert provider_error.context.exit_code == 2
  end

  test "claim/3 routes CLAIMED_BY_OTHER without exposing the assignee value" do
    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", "bead-102b"]}},
                                     %{database_path: "/abs/path"},
                                     [timeout_ms: 30_000] ->
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

    assert {:error, %{code: "CLAIMED_BY_OTHER"} = provider_error} =
             BeadsAdapter.claim("bead-102b", "foreman-actor", %{database_path: "/abs/path"})

    assert provider_error.retryable? == true
    assert provider_error.context.current_assignee_present? == true
    assert "current_assignee" in provider_error.context.redacted_fields
    refute inspect(provider_error) =~ "secret-owner"
  end

  test "claim/3 returns SCHEMA_VALIDATION_FAILED when the claimed issue payload is malformed" do
    start_schema_cache!()

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", "bead-103"]}},
                                     %{database_path: "/abs/path"},
                                     [timeout_ms: 30_000] ->
      {:ok,
       %{
         stdout: Jason.encode!(%{"id" => "bead-103", "status" => "in_progress"}),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:error, %{code: "SCHEMA_VALIDATION_FAILED"} = provider_error} =
             BeadsAdapter.claim("bead-103", "foreman-actor", %{database_path: "/abs/path"})

    assert "title" in provider_error.context.missing_fields
  end

  test "claim/3 returns INVALID_TASK_ID without calling br for empty task ids" do
    assert {:error, %{code: "INVALID_TASK_ID"}} =
             BeadsAdapter.claim("   ", "foreman-actor", %{database_path: "/abs/path"})
  end

  test "claim/3 consumes the cached database_path verbatim" do
    start_schema_cache!()

    cached_database_path = "/tmp/foreman/cache/../claimed.sqlite3"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, [timeout_ms: 30_000] ->
      assert request == {:update, %{flags: ["--claim", "bead-104"]}}
      assert project_config == %{"database_path" => cached_database_path}

      {:ok,
       %{
         stdout: Jason.encode!(issue_payload(%{"id" => "bead-104", "status" => "in_progress"})),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert {:ok, %Issue{id: "bead-104", status: "in_progress"}} =
             BeadsAdapter.claim("bead-104", "foreman-actor", %{
               "database_path" => cached_database_path
             })
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

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
