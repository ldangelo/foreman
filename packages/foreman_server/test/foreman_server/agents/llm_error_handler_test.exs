defmodule ForemanServer.Agents.LlmErrorHandlerTest do
  @moduledoc """
  Tests for ForemanServer.Agents.LlmErrorHandler.
  TRD-2026-4212be7e / JAI-T002 / TRD-040.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.LlmErrorHandler

  describe "with_timeout/2" do
    test "returns :timeout when fun exceeds the timeout" do
      assert {:error, :timeout} =
               LlmErrorHandler.with_timeout(fn -> Process.sleep(100) end, 10)
    end

    test "returns {:ok, value} when fun returns {:ok, value}" do
      assert {:ok, :result} =
               LlmErrorHandler.with_timeout(fn -> {:ok, :result} end, 1000)
    end

    test "wraps a bare value as {:ok, value}" do
      assert {:ok, 42} = LlmErrorHandler.with_timeout(fn -> 42 end, 1000)
    end

    test "propagates an {:error, reason} return" do
      assert {:error, :boom} =
               LlmErrorHandler.with_timeout(fn -> {:error, :boom} end, 1000)
    end

    test "captures Task exit as {:error, {:exit, reason}}" do
      assert {:error, {:exit, _}} =
               LlmErrorHandler.with_timeout(fn -> exit(:crash) end, 1000)
    end
  end

  describe "classify_and_directive/2" do
    test ":timeout is classified as retry" do
      assert {:retry, d} = LlmErrorHandler.classify_and_directive(:timeout)
      assert d.kind == :timeout
      assert d.max_attempts == 3
      assert d.attempt == 1
    end

    test ":rate_limited is classified as retry" do
      assert {:retry, _} = LlmErrorHandler.classify_and_directive(:rate_limited)
    end

    test ":connection_error is classified as retry" do
      assert {:retry, _} = LlmErrorHandler.classify_and_directive(:connection_error)
    end

    test ":auth_failed is classified as escalate" do
      assert {:escalate, d} = LlmErrorHandler.classify_and_directive(:auth_failed)
      assert d.kind == :auth_failed
    end

    test "respects supplied attempt context" do
      assert {:retry, d} =
               LlmErrorHandler.classify_and_directive(:timeout, %{attempt: 2})

      assert d.attempt == 2
    end
  end
end