defmodule ForemanServer.Workflow.FailureClassifierTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.FailureClassifier

  describe "classify/1 — transient errors" do
    test "classifies :model_unreachable as transient" do
      assert FailureClassifier.classify(:model_unreachable) == :transient
    end

    test "classifies :provider_unavailable as transient" do
      assert FailureClassifier.classify(:provider_unavailable) == :transient
    end

    test "classifies :database_unavailable as transient" do
      assert FailureClassifier.classify(:database_unavailable) == :transient
    end

    test "classifies :network_error as transient" do
      assert FailureClassifier.classify(:network_error) == :transient
    end

    test "classifies :worker_dispatch_error as transient" do
      assert FailureClassifier.classify(:worker_dispatch_error) == :transient
    end
  end

  describe "classify/1 — permanent errors" do
    test "classifies :validation_error as permanent" do
      assert FailureClassifier.classify(:validation_error) == :permanent
    end

    test "classifies :workflow_definition_error as permanent" do
      assert FailureClassifier.classify(:workflow_definition_error) == :permanent
    end

    test "classifies :agent_error as permanent" do
      assert FailureClassifier.classify(:agent_error) == :permanent
    end

    test "classifies :phase_terminal as permanent" do
      assert FailureClassifier.classify(:phase_terminal) == :permanent
    end
  end

  describe "classify/1 — unknown errors (default to permanent)" do
    test "defaults :unknown_error to permanent" do
      assert FailureClassifier.classify(:unknown_error) == :permanent
    end

    test "defaults arbitrary atom to permanent" do
      assert FailureClassifier.classify(:some_random_error) == :permanent
    end

    test "defaults string to permanent" do
      assert FailureClassifier.classify("arbitrary error") == :permanent
    end

    test "defaults map to permanent" do
      assert FailureClassifier.classify(%{error: "context"}) == :permanent
    end

    test "defaults nil to permanent" do
      assert FailureClassifier.classify(nil) == :permanent
    end
  end

  describe "classify/1 — parametrized test coverage" do
    # All documented transient errors
    @transient_errors [
      :model_unreachable,
      :provider_unavailable,
      :database_unavailable,
      :network_error,
      :worker_dispatch_error
    ]

    test "all transient errors classify correctly" do
      Enum.each(@transient_errors, fn error ->
        assert FailureClassifier.classify(error) == :transient,
               "Expected #{inspect(error)} to classify as :transient"
      end)
    end

    # All documented permanent errors
    @permanent_errors [
      :validation_error,
      :workflow_definition_error,
      :agent_error,
      :phase_terminal
    ]

    test "all permanent errors classify correctly" do
      Enum.each(@permanent_errors, fn error ->
        assert FailureClassifier.classify(error) == :permanent,
               "Expected #{inspect(error)} to classify as :permanent"
      end)
    end
  end
end
