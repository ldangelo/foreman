defmodule ForemanServer.Idempotency.RestartBackoffTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Idempotency.RestartBackoff

  test "backoff doubles" do
    assert 1000 = RestartBackoff.backoff_ms(1)
    assert 2000 = RestartBackoff.backoff_ms(2)
    assert 16_000 = RestartBackoff.backoff_ms(5)
  end

  test "attempt 6 is blocked" do
    assert {:blocked, :max_attempts_exceeded} = RestartBackoff.next_attempt(6)
  end

  test "attempt 4 retries with delay" do
    assert {:retry, _delay} = RestartBackoff.next_attempt(4)
  end
end
