defmodule ForemanServer.TaskProviders.BeadsAdapterCreateTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    _previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    stub_with(BrRunnerMock, ForemanServer.TaskProviders.UnexpectedBrRunnerStub)

    {:ok, %{}}
  end

  describe "create/2 happy path" do
    test "returns {:ok, %Issue{}} with the br create JSON envelope" do
      register_project!("proj-create-success", "/abs/beads.db")

      attrs = base_attrs()

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
        send(test_pid, {:captured_request, request, runner_project_config, opts})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-200"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{} = issue} = BeadsAdapter.create("proj-create-success", attrs)

      assert issue.id == "bead-200"
      assert issue.title == "Add login"
      assert issue.priority == 2
      assert issue.description == "OAuth flow"

      assert_received {:captured_request, captured_request, %{} = _cfg, [timeout_ms: 30_000]}

      assert {:create, payload} = captured_request
      assert payload.title == "Add login"
      assert payload.type == "feature"
      assert payload.priority == 2
      assert payload.description == "OAuth flow"
      assert is_binary(payload.agent_context)
      assert {:ok, decoded} = Jason.decode(payload.agent_context)
      assert decoded["foreman"]["task_id"] == "tsk-1"
      assert decoded["foreman"]["command_id"] == "cmd-1"
      assert decoded["foreman"]["origin"] == "foreman"
    end

    test "runner-payload does not include :database_path (handler-managed)" do
      register_project!("proj-prop", "/abs/prop.db")

      attrs = base_attrs(%{title: "Propagate"})

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
        send(test_pid, {:captured, request})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-1"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{}} = BeadsAdapter.create("proj-prop", attrs)

      assert_received {:captured, captured_request}
      assert {:create, payload} = captured_request
      assert Map.has_key?(payload, :title)
      assert Map.has_key?(payload, :type)
      assert Map.has_key?(payload, :priority)
      assert Map.has_key?(payload, :description)
      assert Map.has_key?(payload, :agent_context)
      refute Map.has_key?(payload, :database_path)
    end

    test "normalizes nil description to \"\" before constructing the payload" do
      register_project!("proj-desc", "/abs/desc.db")

      attrs = base_attrs(%{description: nil})

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
        send(test_pid, {:captured, request})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-1"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{}} = BeadsAdapter.create("proj-desc", attrs)

      assert_received {:captured, captured_request}
      assert {:create, payload} = captured_request
      assert payload.description == ""
    end

    test "translates task_type to :type key in the runner-payload" do
      register_project!("proj-rename", "/abs/rename.db")

      attrs = base_attrs(%{task_type: "feature"})

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
        send(test_pid, {:captured, request})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-1"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{}} = BeadsAdapter.create("proj-rename", attrs)

      assert_received {:captured, captured_request}
      assert {:create, payload} = captured_request
      assert payload.type == "feature"
    end

    test "captures linked_at as ISO 8601 in agent_context.foreman" do
      register_project!("proj-ts", "/abs/ts.db")

      attrs = base_attrs()

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
        send(test_pid, {:captured, request})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-1"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{}} = BeadsAdapter.create("proj-ts", attrs)

      assert_received {:captured, captured_request}
      assert {:create, payload} = captured_request
      assert {:ok, decoded} = Jason.decode(payload.agent_context)
      assert {:ok, _iso8601, 0} = DateTime.from_iso8601(decoded["foreman"]["linked_at"])
    end

    test "runner-payload has exactly six canonical keys (no extras, no omissions)" do
      register_project!("proj-keys", "/abs/keys.db")

      attrs = base_attrs()

      test_pid = self()

      expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
        send(test_pid, {:captured, request})

        {:ok,
         %{
           stdout: Jason.encode!(create_response_payload(%{"id" => "bead-1"})),
           stderr: "",
           exit_code: 0
         }}
      end)

      assert {:ok, %Issue{}} = BeadsAdapter.create("proj-keys", attrs)

      assert_received {:captured, captured_request}
      assert {:create, payload} = captured_request

      assert payload |> Map.keys() |> Enum.sort() == [
               :agent_context,
               :dedupe_key,
               :description,
               :priority,
               :title,
               :type
             ]

      assert payload.dedupe_key == "dk-1"
    end
  end

  describe "create/2 pre-emptive validation" do
    test "rejects empty :title as INVALID_TITLE (non-retryable)" do
      register_project!("proj-no-title", "/abs/x.db")

      attrs = base_attrs(%{title: ""})

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-no-title", attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects empty :task_id correlation handle as INVALID_TITLE" do
      register_project!("proj-no-task-id", "/abs/x.db")

      attrs = base_attrs(%{task_id: ""})

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-no-task-id", attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects empty :command_id correlation handle as INVALID_TITLE" do
      register_project!("proj-no-command-id", "/abs/x.db")

      attrs = base_attrs(%{command_id: ""})

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-no-command-id", attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects out-of-range :priority as INVALID_PRIORITY (non-retryable)" do
      register_project!("proj-bad-priority", "/abs/x.db")

      attrs = base_attrs(%{priority: 99})

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-bad-priority", attrs)

      assert err.code == "INVALID_PRIORITY"
      assert err.retryable? == false
    end

    test "rejects out-of-enum :task_type as INVALID_ISSUE_TYPE (non-retryable)" do
      register_project!("proj-bad-type", "/abs/x.db")

      attrs = base_attrs(%{task_type: "story"})

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-bad-type", attrs)

      assert err.code == "INVALID_ISSUE_TYPE"
      assert err.retryable? == false
    end

    test "rejects non-binary project_id at the boundary clause" do
      attrs = base_attrs()

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create(:not_a_string, attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects non-map attrs at the boundary clause" do
      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-some", :not_a_map)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects attrs missing :task_id correlation handle as INVALID_TITLE" do
      register_project!("proj-missing-task-id", "/abs/x.db")

      attrs =
        Map.delete(base_attrs(), :task_id)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-missing-task-id", attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects attrs missing :command_id correlation handle as INVALID_TITLE" do
      register_project!("proj-missing-cmd-id", "/abs/x.db")

      attrs =
        Map.delete(base_attrs(), :command_id)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-missing-cmd-id", attrs)

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end

    test "rejects a minimal %{title: \"x\"} map missing the other six canonical keys as INVALID_TITLE" do
      register_project!("proj-sparse", "/abs/x.db")

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-sparse", %{title: "x"})

      assert err.code == "INVALID_TITLE"
      assert err.retryable? == false
    end
  end

  describe "create/2 registry resolution failures" do
    test "returns CREATE_FAILED (non-retryable) when Registry.project_config/1 is missing the project" do
      attrs = base_attrs()

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-missing", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
      assert err.context.project_id == "proj-missing"
      assert err.context.reason == :task_provider_not_configured
    end

    test "returns CREATE_FAILED (non-retryable) when Registry marks the project unavailable" do
      register_project!("proj-down", "/abs/x.db")
      :ok = Registry.unregister_for_project("proj-down", :br_binary_missing)

      attrs = base_attrs()

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-down", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
      assert err.context.reason == :provider_unavailable_for_project
    end

    test "returns CREATE_FAILED (non-retryable) when the registered config has no :database_path" do
      assert :ok =
               Registry.register_for_project(
                 "proj-no-dbpath",
                 BeadsAdapter,
                 %{}
               )

      attrs = base_attrs()

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-no-dbpath", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
      assert err.context.reason == :missing_database_path
    end
  end

  describe "create/2 br response failures" do
    test "returns CREATE_FAILED (non-retryable) when br output is empty" do
      register_project!("proj-empty", "/abs/empty.db")

      attrs = base_attrs()

      expect(BrRunnerMock, :cmd, 1, fn _request, _project_config, _opts ->
        {:ok, %{stdout: "", stderr: "", exit_code: 0}}
      end)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-empty", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
    end

    test "returns CREATE_FAILED (non-retryable) when br output is not JSON" do
      register_project!("proj-bad-json", "/abs/x.db")

      attrs = base_attrs()

      expect(BrRunnerMock, :cmd, 1, fn _request, _project_config, _opts ->
        {:ok, %{stdout: "not json {", stderr: "", exit_code: 0}}
      end)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-bad-json", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
    end

    test "returns CREATE_FAILED (non-retryable) when br output is a JSON array instead of an object" do
      register_project!("proj-array", "/abs/x.db")

      attrs = base_attrs()

      expect(BrRunnerMock, :cmd, 1, fn _request, _project_config, _opts ->
        {:ok, %{stdout: "[]", stderr: "", exit_code: 0}}
      end)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-array", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
    end

    test "returns CREATE_FAILED (non-retryable) for unknown br failure (BR_PARSE_ERROR fallback)" do
      register_project!("proj-fallback", "/abs/x.db")

      attrs = base_attrs()

      expect(BrRunnerMock, :cmd, 1, fn _request, _project_config, _opts ->
        {:error, %{stdout: "garbage", stderr: "segfault", exit_code: 139}}
      end)

      assert {:error, %ProviderError{} = err} = BeadsAdapter.create("proj-fallback", attrs)

      assert err.code == "CREATE_FAILED"
      assert err.retryable? == false
    end
  end

  ## Helpers

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "tsk-1",
        command_id: "cmd-1",
        title: "Add login",
        description: "OAuth flow",
        priority: 2,
        task_type: "feature",
        dedupe_key: "dk-1"
      },
      overrides
    )
  end

  defp register_project!(project_id, database_path) do
    assert :ok =
             Registry.register_for_project(project_id, BeadsAdapter, %{
               database_path: database_path
             })

    assert {:ok, %{provider_module: BeadsAdapter, config: project_config}} =
             Registry.project_config(project_id)

    project_config
  end

  defp create_response_payload(overrides) do
    Map.merge(
      %{
        "id" => "bead-200",
        "title" => "Add login",
        "status" => "open",
        "priority" => 2,
        "dependencies" => [],
        "assignee" => nil,
        "description" => "OAuth flow",
        "notes" => nil,
        "design" => nil,
        "labels" => ["foreman"],
        "metadata" => %{"agent_context" => %{"foreman" => %{"task_id" => "tsk-1"}}}
      },
      overrides
    )
  end
end
