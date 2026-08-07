defmodule ForemanServer.TaskProviders.BeadsAdapterTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError

  @expected_capabilities %{
    provider_id: :beads,
    contract_version: "br.capabilities.v1",
    supports: [
      :claim,
      :close,
      :reopen,
      :annotate,
      :set_priority,
      :set_assignee,
      :list_dependencies,
      :add_dependency,
      :remove_dependency
    ]
  }
  @expected_callbacks TaskProvider.behaviour_info(:callbacks)
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

  test "Application.compile_env resolves BrRunnerMock in :test" do
    assert BeadsAdapter.__runner__() == BrRunnerMock
  end

  test "name/0 returns :beads" do
    assert BeadsAdapter.name() == :beads
  end

  test "capabilities/0 returns expected map" do
    assert BeadsAdapter.capabilities() == @expected_capabilities
  end

  test "available?/0 returns false when br is not on PATH" do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end
    end)

    System.put_env("PATH", "")

    assert BeadsAdapter.available?() == false
  end

  test "available?/0 returns true when br is on PATH" do
    assert is_binary(System.find_executable("br"))
    assert BeadsAdapter.available?() == true
  end

  test "11 callbacks are defined" do
    assert length(@expected_callbacks) == 11
    assert BeadsAdapter.behaviour_info(:callbacks) == @expected_callbacks

    Enum.each(@expected_callbacks, fn {name, arity} ->
      assert function_exported?(BeadsAdapter, name, arity)
    end)
  end

  describe "list_ready/2" do
    test "maps ready issues to Issue structs and consumes the cached database_path verbatim" do
      start_schema_cache!()

      cached_database_path = "/tmp/foreman/cache/../beads.sqlite3"

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
          "metadata" => %{"provider_id" => "beads", "source" => "br ready"}
        },
        %{
          "id" => "bead-102",
          "title" => "Cover empty projects",
          "status" => "blocked",
          "priority" => 4,
          "dependencies" => ["opaque:dep-3"],
          "assignee" => "mox",
          "description" => "Second issue",
          "notes" => "Populate all fields",
          "design" => "Schema-backed mapping",
          "labels" => ["tests"],
          "metadata" => %{"provider_id" => "beads", "source" => "br ready"}
        }
      ]

      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        assert request == {:ready, %{database_path: cached_database_path}}
        assert project_config == %{"database_path" => cached_database_path}
        assert opts == [timeout_ms: 30_000]

        {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
      end)

      assert {:ok, [first_issue, second_issue]} =
               BeadsAdapter.list_ready(%{"database_path" => cached_database_path}, [])

      assert first_issue == %Issue{
               id: "bead-101",
               title: "Ship TRD-011",
               status: "blocked",
               priority: 2,
               dependencies: ["opaque:dep-1", "dep/2"],
               assignee: "leo",
               description: "List ready issues",
               notes: "Keep dependency ids opaque",
               design: "Use cached config",
               labels: ["backend", "beads"],
               metadata: %{"provider_id" => "beads", "source" => "br ready"}
             }

      assert second_issue == %Issue{
               id: "bead-102",
               title: "Cover empty projects",
               status: "blocked",
               priority: 4,
               dependencies: ["opaque:dep-3"],
               assignee: "mox",
               description: "Second issue",
               notes: "Populate all fields",
               design: "Schema-backed mapping",
               labels: ["tests"],
               metadata: %{"provider_id" => "beads", "source" => "br ready"}
             }
    end

    test "returns SCHEMA_VALIDATION_FAILED when br ready returns malformed payload" do
      start_schema_cache!()

      expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/path"}},
                                       %{database_path: "/abs/path"},
                                       [timeout_ms: 30_000] ->
        {:ok,
         %{stdout: Jason.encode!([%{"id" => 123, "status" => "open"}]), stderr: "", exit_code: 0}}
      end)

      assert {:error, %ProviderError{} = provider_error} =
               BeadsAdapter.list_ready(%{database_path: "/abs/path"}, [])

      assert provider_error.code == "SCHEMA_VALIDATION_FAILED"
      assert provider_error.retryable? == false
      assert provider_error.context.command == "br ready"
      assert "title" in provider_error.context.missing_fields
    end

    test "defensively re-asserts blocked status even when br reports open" do
      start_schema_cache!()

      expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/path"}},
                                       %{database_path: "/abs/path"},
                                       [timeout_ms: 30_000] ->
        payload = [
          %{
            "id" => "bead-103",
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
        ]

        {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
      end)

      assert {:ok, [%Issue{status: "blocked"} = issue]} =
               BeadsAdapter.list_ready(%{database_path: "/abs/path"}, [])

      assert issue.id == "bead-103"
      assert issue.priority == 1
      assert issue.dependencies == []
    end

    test "returns {:ok, []} when br ready reports no ready issues" do
      start_schema_cache!()

      expect(BrRunnerMock, :cmd, 1, fn {:ready, %{database_path: "/abs/path"}},
                                       %{database_path: "/abs/path"},
                                       [timeout_ms: 30_000] ->
        {:ok, %{stdout: "[]", stderr: "", exit_code: 0}}
      end)

      assert {:ok, []} == BeadsAdapter.list_ready(%{database_path: "/abs/path"}, [])
    end
  end

  test "unimplemented callbacks return {:error, :not_implemented}" do
    assert BeadsAdapter.get("issue-1", %{}) == {:error, :not_implemented}
    assert BeadsAdapter.claim("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.complete("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.fail("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.reopen("issue-1", "retry", %{}) == {:error, :not_implemented}
    assert BeadsAdapter.add_dependency("issue-1", "issue-2", %{}) == {:error, :not_implemented}
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
