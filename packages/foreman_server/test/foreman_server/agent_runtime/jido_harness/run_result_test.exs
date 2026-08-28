defmodule ForemanServer.AgentRuntime.JidoHarness.RunResultTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.RunResult

  describe "module reachability" do
    test "is loadable from consumer code" do
      assert Code.ensure_loaded?(RunResult),
             "ForemanServer.AgentRuntime.JidoHarness.RunResult must be loadable"
    end
  end

  describe "normalize/1 — successful runs" do
    test "returns {:ok, text, metadata} for a completed run with no error" do
      result = build_result(status: :completed, text: "pong")

      assert {:ok, "pong", metadata} = RunResult.normalize(result)
      assert metadata == %{provider: :pi, adapter: :jido_harness}
    end

    test "preserves the bounded text verbatim, including the empty string" do
      empty = build_result(status: :completed, text: "")
      non_empty = build_result(status: :completed, text: "hello world")

      assert {:ok, "", %{adapter: :jido_harness}} = RunResult.normalize(empty)
      assert {:ok, "hello world", %{adapter: :jido_harness}} = RunResult.normalize(non_empty)
    end

    test "propagates the upstream :provider atom into metadata" do
      result = build_result(status: :completed, text: "ok", provider: :codex)

      assert {:ok, "ok", %{provider: :codex, adapter: :jido_harness}} =
               RunResult.normalize(result)
    end

    test "metadata map always carries adapter: :jido_harness regardless of provider" do
      result = build_result(status: :completed, text: "ok", provider: :claude)

      assert {:ok, _, %{adapter: :jido_harness}} = RunResult.normalize(result)
    end
  end

  describe "normalize/1 — failed runs" do
    test "delegates a known :failed error code to ErrorCodes.map/1" do
      result = build_result(status: :failed, error: %{code: :tool_error})

      assert {:error, :tool_error} = RunResult.normalize(result)
    end

    test "delegates :process_terminated to ErrorCodes.map/1" do
      result = build_result(status: :failed, error: %{code: :process_terminated})

      assert {:error, :process_terminated} = RunResult.normalize(result)
    end

    test "delegates :timeout to ErrorCodes.map/1" do
      result = build_result(status: :failed, error: %{code: :timeout})

      assert {:error, :timeout} = RunResult.normalize(result)
    end

    test "reports :failed_without_detail — not :unknown_error — for a :failed run with nil error" do
      result = build_result(status: :failed, error: nil)

      assert RunResult.normalize(result) == {:error, :failed_without_detail}
    end

    test "maps a %Jido.Harness.Error{} category through ErrorCodes (:timeout)" do
      result =
        build_result(
          status: :failed,
          error: Jido.Harness.Error.new(:timeout, "provider timed out", run_id: "r-1")
        )

      assert RunResult.normalize(result) == {:error, :timeout}
    end

    test "preserves an unrecognized %Jido.Harness.Error{} category under {:other, category}" do
      result =
        build_result(status: :failed, error: Jido.Harness.Error.execution("stub failure"))

      assert RunResult.normalize(result) == {:error, {:other, :execution}}
    end

    test "preserves an unrecognized :failed error code under {:other, code}" do
      result = build_result(status: :failed, error: %{code: :provider_disconnected})

      assert {:error, {:other, :provider_disconnected}} = RunResult.normalize(result)
    end

    test "falls back to :unknown_error for a :failed run with a non-map error term" do
      result = build_result(status: :failed, error: :boom)

      assert {:error, :unknown_error} = RunResult.normalize(result)
    end
  end

  describe "normalize/1 — cancelled runs" do
    test "maps a :cancelled run with error %{code: :cancelled} to {:error, :cancelled}" do
      result = build_result(status: :cancelled, error: %{code: :cancelled})

      assert {:error, :cancelled} = RunResult.normalize(result)
    end

    test "reports :cancelled — not :unknown_error — for a :cancelled run with nil error" do
      result = build_result(status: :cancelled, error: nil)

      assert RunResult.normalize(result) == {:error, :cancelled}
    end
  end

  describe "normalize/1 — forward-compatible statuses" do
    # `Jido.Harness.RunResult.new!/1` validates `status` against the current
    # upstream enum, so the struct is built directly to exercise the
    # defensive clause a future upstream status would hit.
    test "preserves an unknown non-:completed status under {:other, status}" do
      result = %Jido.Harness.RunResult{
        run_id: "r-1",
        provider: :pi,
        status: :suspended,
        text: "",
        error: nil
      }

      assert RunResult.normalize(result) == {:error, {:other, :suspended}}
    end
  end

  describe "normalize/1 — completed with error (inconsistent upstream state)" do
    test "errors when a :completed run carries a non-nil :error" do
      result = build_result(status: :completed, text: "pong", error: %{code: :timeout})

      assert {:error, :timeout} = RunResult.normalize(result)
    end
  end

  ## Helpers

  # Builds a valid `%Jido.Harness.RunResult{}` struct using the upstream
  # schema's constructor. Required attrs: `:run_id`, `:provider`, `:status`.
  # Optional attrs (with their schema defaults): `:text` (""), `:error` (nil).
  defp build_result(attrs) do
    base = %{
      run_id: "run-#{System.unique_integer([:positive])}",
      provider: :pi,
      status: :completed,
      text: "",
      error: nil
    }

    Jido.Harness.RunResult.new!(Map.merge(base, Map.new(attrs)))
  end
end
