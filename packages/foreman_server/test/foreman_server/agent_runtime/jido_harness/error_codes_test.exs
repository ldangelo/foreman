defmodule ForemanServer.AgentRuntime.JidoHarness.ErrorCodesTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.ErrorCodes

  describe "map/1 — nil input" do
    test "returns nil when the error is nil" do
      assert ErrorCodes.map(nil) == nil
    end
  end

  describe "map/1 — known error codes" do
    test "maps %{code: :tool_error} to {:error, :tool_error}" do
      assert ErrorCodes.map(%{code: :tool_error}) == {:error, :tool_error}
    end

    test "maps %{code: :process_terminated} to {:error, :process_terminated}" do
      assert ErrorCodes.map(%{code: :process_terminated}) == {:error, :process_terminated}
    end

    test "maps %{code: :unsupported_provider} to {:error, :unsupported_provider}" do
      assert ErrorCodes.map(%{code: :unsupported_provider}) == {:error, :unsupported_provider}
    end

    test "maps %{code: :timeout} to {:error, :timeout}" do
      assert ErrorCodes.map(%{code: :timeout}) == {:error, :timeout}
    end

    test "maps %{code: :cancelled} to {:error, :cancelled}" do
      assert ErrorCodes.map(%{code: :cancelled}) == {:error, :cancelled}
    end
  end

  describe "map/1 — unknown code" do
    test "preserves an unrecognized :code as {:error, {:other, :unknown}}" do
      assert ErrorCodes.map(%{code: :unknown}) == {:error, {:other, :unknown}}
    end

    test "preserves a non-atom :code as {:error, {:other, term()}}" do
      assert ErrorCodes.map(%{code: "string"}) == {:error, {:other, "string"}}
      assert ErrorCodes.map(%{code: 42}) == {:error, {:other, 42}}
    end
  end

  describe "map/1 — malformed input" do
    test "returns {:error, :unknown_error} for a non-map term" do
      assert ErrorCodes.map(:something) == {:error, :unknown_error}
    end

    test "returns {:error, :unknown_error} for a map without :code" do
      assert ErrorCodes.map(%{}) == {:error, :unknown_error}
    end


    test "returns {:error, :unknown_error} for a struct" do
      result = Jido.Harness.RunResult.new!(%{run_id: "r-1", provider: :pi, status: :failed})
      assert ErrorCodes.map(result) == {:error, :unknown_error}
    end
  end
end
