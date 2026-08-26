defmodule ForemanServer.Idempotency.RestartBackoff do
  @moduledoc "5-restart backoff loop. TRD-2026-4212be7e / RTE-T004 / TRD-078."

  require Logger

  @max_attempts 5

  def should_restart?(attempt), do: attempt <= @max_attempts

  def backoff_ms(attempt), do: trunc(1000 * :math.pow(2, attempt - 1))

  def next_attempt(attempt) do
    if should_restart?(attempt) do
      Logger.warning("Retry attempt=#{attempt} delay_ms=#{backoff_ms(attempt)}")
      {:retry, backoff_ms(attempt)}
    else
      Logger.error("Max attempts (#{@max_attempts}) exceeded; blocking")
      {:blocked, :max_attempts_exceeded}
    end
  end
end
