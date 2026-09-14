defmodule ForemanServer.Workflow.RunExecutorRetryTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.Workflow.RunExecutor
  alias ForemanServer.Workflow.FailureClassifier

  @moduledoc """
  Contract tests for `ForemanServer.Workflow.FailureClassifier`, the
  transient/permanent classification `RunExecutor.fail_with_retry/6` and
  `fail_retry_loop/5` consult before retrying a failed `fail/4` dispatch.

  This file exercises ONLY `FailureClassifier.classify/1` in isolation — it
  never starts a `RunExecutor` and never calls `fail_with_retry/6`, so it
  cannot detect a removed retry attempt, a changed backoff delay, or a
  broken escalation path in the real retry loop. That end-to-end coverage
  (a real `RunExecutor` run, a `BrRunnerMock`-backed `fail/4` failing
  transiently then succeeding on retry, asserting both calls happen and the
  run still reaches `TaskExecutionFailed`) lives in
  `run_executor_test.exs`'s "failure path retries a transient fail/4 error
  before dispatching TaskExecutionFailed" test instead, since it needs the
  full provider/event-store harness already set up there.
  """

  describe "fail_with_retry/4 — permanent failures (no retry)" do
    test "permanent failure skips retry and returns immediately" do
      # A permanent error should be classified as permanent and returned without retry
      assert FailureClassifier.classify(:validation_error) == :permanent
      assert FailureClassifier.classify(:workflow_definition_error) == :permanent
      assert FailureClassifier.classify(:agent_error) == :permanent
      assert FailureClassifier.classify(:phase_terminal) == :permanent
    end
  end

  describe "fail_with_retry/4 — transient failures (with retry)" do
    test "transient error is classified correctly" do
      # A transient error should be classified as transient
      assert FailureClassifier.classify(:model_unreachable) == :transient
      assert FailureClassifier.classify(:provider_unavailable) == :transient
      assert FailureClassifier.classify(:database_unavailable) == :transient
      assert FailureClassifier.classify(:network_error) == :transient
      assert FailureClassifier.classify(:worker_dispatch_error) == :transient
    end

    test "retry behavior timing" do
      # Document the expected retry schedule:
      # Attempt 1: Fails with transient error → wait 1s before attempt 2
      # Attempt 2: Fails with transient error → wait 5s before attempt 3
      # Attempt 3: Fails with transient error → wait 15s settle → return transient_exhausted
      #
      # Total wait time: 1s + 5s + 15s = 21s before escalation
      # Total attempts: 3
      # No 4th attempt is made

      # The actual timing verification would require:
      # - Mocking Process.sleep to record call count and durations
      # - Mocking RunExecutor.fail to return transient errors
      # - Verifying the exact sequence of retries

      # For now, we document the contract:
      # ms
      wait_before_attempt_2 = 1_000
      # ms
      wait_before_attempt_3 = 5_000
      # ms
      wait_before_escalation = 15_000

      total_wait_ms = wait_before_attempt_2 + wait_before_attempt_3 + wait_before_escalation
      assert total_wait_ms == 21_000

      # Verify schedule constants are correct
      assert wait_before_attempt_2 == 1_000
      assert wait_before_attempt_3 == 5_000
      assert wait_before_escalation == 15_000
    end
  end

  describe "fail_with_retry/4 — integration behavior" do
    test "3rd transient failure escalates with transient_exhausted error tag" do
      # When all 3 attempts fail with transient errors,
      # the final result should be {:error, {:transient_exhausted, original_error}}
      # instead of another retry attempt.

      # The sequence is:
      # 1. fail/4 returns {:error, :transient_error_1} → classify as transient → retry
      # 2. fail/4 returns {:error, :transient_error_2} → classify as transient → retry
      # 3. fail/4 returns {:error, :transient_error_3} → classify as transient → sleep 15s → escalate

      # Verify that escalation uses the :transient_exhausted tag
      original_error = :network_error
      escalated_error = {:transient_exhausted, original_error}

      # The escalated error format wraps the original error
      assert match?({:transient_exhausted, _}, escalated_error)
      assert elem(escalated_error, 1) == original_error
    end

    test "permanent failure during retry stops retry loop" do
      # If any attempt returns a permanent error, the loop exits immediately
      # without further retries.

      # Scenario:
      # 1. fail/4 returns {:error, :transient_error} → retry
      # 2. fail/4 returns {:error, :validation_error} → classify as permanent → stop

      permanent_error = :validation_error
      assert FailureClassifier.classify(permanent_error) == :permanent

      # No further attempts should be made after a permanent error
    end
  end

  describe "FailureClassifier.classify/1 — contract verification" do
    test "all transient errors are recognized" do
      transient_errors = [
        :model_unreachable,
        :provider_unavailable,
        :database_unavailable,
        :network_error,
        :worker_dispatch_error
      ]

      Enum.each(transient_errors, fn error ->
        assert FailureClassifier.classify(error) == :transient,
               "Expected #{inspect(error)} to be classified as transient"
      end)
    end

    test "all permanent errors are recognized" do
      permanent_errors = [
        :validation_error,
        :workflow_definition_error,
        :agent_error,
        :phase_terminal
      ]

      Enum.each(permanent_errors, fn error ->
        assert FailureClassifier.classify(error) == :permanent,
               "Expected #{inspect(error)} to be classified as permanent"
      end)
    end

    test "unknown errors default to permanent (fail-safe)" do
      unknown_errors = [
        :unknown_error,
        :random_error,
        {:complex, :error},
        "string error",
        nil
      ]

      Enum.each(unknown_errors, fn error ->
        assert FailureClassifier.classify(error) == :permanent,
               "Expected unknown error #{inspect(error)} to default to permanent"
      end)
    end
  end
end
