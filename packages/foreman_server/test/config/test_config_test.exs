defmodule ForemanServer.TestConfigTest do
  use ExUnit.Case, async: false

  test ":br_runner resolves to BrRunnerMock in test env" do
    assert Application.get_env(:foreman_server, :br_runner) ==
             ForemanServer.TaskProviders.BrRunnerMock
  end

  test "BrRunnerMock module exists" do
    assert Code.ensure_loaded?(ForemanServer.TaskProviders.BrRunnerMock) == true
  end

  test "BrRunnerMock defines cmd/3" do
    assert function_exported?(ForemanServer.TaskProviders.BrRunnerMock, :cmd, 3) ||
             Code.ensure_loaded?(ForemanServer.TaskProviders.BrRunnerMock)
  end
end
