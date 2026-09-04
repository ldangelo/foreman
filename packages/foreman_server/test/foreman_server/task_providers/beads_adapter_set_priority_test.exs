defmodule ForemanServer.TaskProviders.BeadsAdapterSetPriorityTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemBrRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_with(BrRunnerMock, ForemanServer.TaskProviders.UnexpectedBrRunnerStub)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "beads_adapter_set_priority_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)

    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "set_priority/3 returns :ok for priority 2", %{temp_dir: temp_dir} do
    cached_path = "/abs/path/priority-2.db"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "task-1", priority: 2, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["update", "--db", cached_path, "task-1", "--priority", "2", "--json"]
      )

      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("task-1", 2, %{database_path: cached_path})
  end

  test "set_priority/3 accepts priority 0", %{temp_dir: temp_dir} do
    cached_path = "/abs/path/priority-0.db"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "task-1", priority: 0, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["update", "--db", cached_path, "task-1", "--priority", "0", "--json"]
      )

      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("task-1", 0, %{database_path: cached_path})
  end

  test "set_priority/3 accepts priority 4", %{temp_dir: temp_dir} do
    cached_path = "/abs/path/priority-4.db"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "task-1", priority: 4, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["update", "--db", cached_path, "task-1", "--priority", "4", "--json"]
      )

      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("task-1", 4, %{database_path: cached_path})
  end

  test "set_priority/3 rejects priority -1 before reading config or invoking br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("task-1", -1, :ignored)

    assert provider_error.code == "INVALID_PRIORITY"
    assert provider_error.message == "Issue priority must be between 0 and 4."
    assert provider_error.hint == "Pass a Beads priority level in the inclusive range 0..4."
    assert provider_error.retryable? == false
    assert provider_error.context.id == "INVALID_PRIORITY"
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "set_priority/3 rejects priority 5 before reading config or invoking br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("task-1", 5, :ignored)

    assert provider_error.code == "INVALID_PRIORITY"
    assert provider_error.message == "Issue priority must be between 0 and 4."
    assert provider_error.hint == "Pass a Beads priority level in the inclusive range 0..4."
    assert provider_error.retryable? == false
    assert provider_error.context.id == "INVALID_PRIORITY"
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
  end

  test "set_priority/3 maps br failure envelopes through CodeMap", %{temp_dir: temp_dir} do
    cached_path = "/abs/path.db"

    stderr =
      Jason.encode!(%{
        "code" => "BR_DATABASE_LOCKED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "task-1", priority: 2, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["update", "--db", cached_path, "task-1", "--priority", "2", "--json"]
      )

      {:error, %{stdout: "", stderr: stderr, exit_code: 73}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("task-1", 2, %{database_path: cached_path})

    assert provider_error.code == "BR_DATABASE_LOCKED"
    assert provider_error.retryable? == true
    assert provider_error.message == "Beads database is locked."
    assert provider_error.hint == "Retry after the current database lock is released."
    assert provider_error.context.id == "BR_DATABASE_LOCKED"
    assert provider_error.context.command == "br update"
    assert provider_error.context.exit_code == 73
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
  end

  test "set_priority/3 consumes the exact cached database_path registered for the project",
       %{temp_dir: temp_dir} do
    put_fake_br_on_path!(temp_dir, "exit 0")

    original_task_provider_config = Application.get_env(:foreman_server, :task_provider)

    on_exit(fn ->
      case original_task_provider_config do
        nil -> Application.delete_env(:foreman_server, :task_provider)
        config -> Application.put_env(:foreman_server, :task_provider, config)
      end
    end)

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    project_id = "proj-x"
    cached_path = "/abs/cached/../path.db"

    assert :ok =
             Registry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => cached_path
             })

    assert {:ok, BeadsAdapter} = Registry.route(:set_priority, {project_id, cached_path})

    registered_config = registered_project_config(project_id)

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "task-1", priority: 2, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["update", "--db", cached_path, "task-1", "--priority", "2", "--json"]
      )

      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("task-1", 2, registered_config)
  end

  defp registered_project_config(project_id) do
    assert %{per_project: %{^project_id => {:active, %{config: config}}}} =
             :sys.get_state(Registry)

    config
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

  defp put_fake_br_on_path!(temp_dir, body) do
    original_path = System.get_env("PATH") || ""
    write_fake_br!(temp_dir, body)
    System.put_env("PATH", temp_dir <> ":" <> original_path)
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
end
