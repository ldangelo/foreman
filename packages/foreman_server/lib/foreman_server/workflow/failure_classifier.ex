defmodule ForemanServer.Workflow.FailureClassifier do
  @moduledoc """
  Classifies run failures as transient (retryable) or permanent (not retryable).

  Transient failures are infrastructure-caused and can be retried automatically:
  - :model_unreachable — model provider unavailable
  - :provider_unavailable — task provider (e.g., Beads) unavailable
  - :database_unavailable — database connectivity issue
  - :network_error — network-level failure
  - :worker_dispatch_error — worker or dispatch infrastructure failure

  Permanent failures indicate the run definition or execution is invalid and
  should not be retried:
  - :validation_error — input validation failed
  - :workflow_definition_error — workflow manifest is invalid
  - :agent_error — agent-side error (tool, code, etc.)
  - :phase_terminal — phase reached a terminal error state (no retry)

  Unknown errors default to permanent (fail-safe: do not retry).
  """

  @transient_errors [
    :model_unreachable,
    :provider_unavailable,
    :database_unavailable,
    :network_error,
    :worker_dispatch_error
  ]

  @permanent_errors [
    :validation_error,
    :workflow_definition_error,
    :agent_error,
    :phase_terminal
  ]

  @doc """
  Classifies a failure reason as `:transient` or `:permanent`.

  Returns `:transient` if the error can be retried, `:permanent` if it cannot.
  Unknown errors default to `:permanent` (fail-safe).

  ## Examples

      iex> ForemanServer.Workflow.FailureClassifier.classify(:model_unreachable)
      :transient

      iex> ForemanServer.Workflow.FailureClassifier.classify(:validation_error)
      :permanent

      iex> ForemanServer.Workflow.FailureClassifier.classify(:unknown_error)
      :permanent
  """
  @spec classify(term()) :: :transient | :permanent
  def classify(reason) when reason in @transient_errors do
    :transient
  end

  def classify(reason) when reason in @permanent_errors do
    :permanent
  end

  # Unknown errors default to permanent (fail-safe)
  def classify(_reason) do
    :permanent
  end
end
