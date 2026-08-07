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
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:set_priority, %{id: "x", priority: 2, database_path: "/abs/path"}}
      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.set_priority("x", 2, %{database_path: "/abs/path"})
    assert :ok == Mox.verify!()
  end

  test "set_priority/3 rejects invalid priority before calling br" do
    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.set_priority("x", 99, %{database_path: "/abs/path"})

    assert provider_error.code == "INVALID_PRIORITY"
    assert provider_error.retryable? == false
    assert provider_error.message == "Issue priority must be between 0 and 4."
    assert provider_error.hint == "Pass a Beads priority level in the inclusive range 0..4."

    assert provider_error.context == %{
             id: "INVALID_PRIORITY",
             command: nil,
             exit_code: nil,
             stderr_byte_count: 0,
             sanitized?: true,
             redacted_fields: [],
             missing_fields: []
           }

    assert :ok == Mox.verify!()
  end
end
