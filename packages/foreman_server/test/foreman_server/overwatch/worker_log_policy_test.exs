defmodule ForemanServer.Overwatch.WorkerLogPolicyTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Overwatch.WorkerLogPolicy

  test "redacts bearer tokens, key-value secrets, and configured secret values before persistence" do
    line = "Bearer abc.def token=super-secret api_key=abc123 exact-value"

    assert WorkerLogPolicy.redact(line, ["exact-value"]) ==
             "Bearer [REDACTED] token=[REDACTED] api_key=[REDACTED] [REDACTED]"
  end

  test "escapes unsafe control characters while preserving visible text" do
    assert WorkerLogPolicy.escape_control_chars("ok\r\t" <> <<0, 31, 127>>) ==
             "ok\\r\\t\\u0000\\u001F\\u007F"
  end

  test "enforces line and byte caps with omitted counters" do
    assert {:emit, "one", counters} =
             WorkerLogPolicy.normalize("one", WorkerLogPolicy.initial_counters(), max_lines: 1)

    assert {:drop, %{omitted_lines: 1, omitted_bytes: 3}} =
             WorkerLogPolicy.normalize("two", counters, max_lines: 1)

    assert {:drop, %{omitted_lines: 1, omitted_bytes: 6}} =
             WorkerLogPolicy.normalize("123456", WorkerLogPolicy.initial_counters(), max_bytes: 5)
  end
end
