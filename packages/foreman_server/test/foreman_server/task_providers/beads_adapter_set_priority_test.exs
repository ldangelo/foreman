defmodule ForemanServer.TaskProviders.BeadsAdapterSetPriorityTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    :ok
  end

  test "set_priority/3 returns :ok when br update succeeds with cached database_path" do
    cached_path = "/tmp/foreman/cache/../beads.db"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "x", priority: 2, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("x", 2, %{database_path: cached_path})
    assert :ok == Mox.verify!()
  end

  test "set_priority/3 consumes cached database_path without expanding it again" do
    cached_path = "/opt/foreman/cache/../beads.db"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "x", priority: 2, database_path: cached_path}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("x", 2, %{"database_path" => cached_path})
    assert :ok == Mox.verify!()
  end

  test "set_priority/3 rejects priority -1 before calling br or reading project_config" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("x", -1, %{})

    assert provider_error.code == "INVALID_PRIORITY"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
    assert :ok == Mox.verify!()
  end

  test "set_priority/3 rejects priority 5 before calling br or reading project_config" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("x", 5, %{})

    assert provider_error.code == "INVALID_PRIORITY"
    assert provider_error.retryable? == false
    assert provider_error.context.command == nil
    assert provider_error.context.stderr_byte_count == 0
    assert :ok == Mox.verify!()
  end

  test "set_priority/3 maps br failure envelopes through CodeMap" do
    stderr =
      Jason.encode!(%{
        "code" => "BR_DATABASE_LOCKED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "x", priority: 2, database_path: "/abs/path"}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]
      {:error, %{stdout: "", stderr: stderr, exit_code: 73}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("x", 2, %{database_path: "/abs/path"})

    assert provider_error.code == "BR_DATABASE_LOCKED"
    assert provider_error.retryable? == true
    assert provider_error.message == "Beads database is locked."
    assert provider_error.hint == "Retry after the current database lock is released."
    assert provider_error.context.command == "br update"
    assert provider_error.context.exit_code == 73
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
    assert :ok == Mox.verify!()
  end
end
