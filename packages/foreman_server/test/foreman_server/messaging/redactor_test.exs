defmodule ForemanServer.Messaging.RedactorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Messaging.Redactor

  test "redacts a secret embedded inside an error reason tuple" do
    assert {:missing_or_invalid, :recipient, "https://hooks.slack.com/services/[REDACTED]"} =
             Redactor.redact(
               {:missing_or_invalid, :recipient, "https://hooks.slack.com/services/T/B/C"}
             )
  end

  test "redacts secrets nested inside a map inside a tuple" do
    assert {:missing_or_invalid, :metadata, %{token: "bot[REDACTED]"}} =
             Redactor.redact(
               {:missing_or_invalid, :metadata,
                %{token: "bot123456:abcdefghijklmnopqrstuvwxyzABCDE"}}
             )
  end

  test "leaves a tuple with no secrets unchanged" do
    assert {:unknown_keys, [:extra]} = Redactor.redact({:unknown_keys, [:extra]})
  end

  test "redacts a secret in a printable charlist, preserving the charlist result" do
    # A charlist is a list of codepoints: the generic list clause maps
    # `redact/1` over each integer and hands them to the catch-all clause
    # unchanged, so the secret previously survived untouched (CodeRabbit
    # review).
    assert ~c"https://hooks.slack.com/services/[REDACTED]" =
             Redactor.redact(~c"https://hooks.slack.com/services/T/B/C")
  end

  test "redacts a secret in a charlist nested inside a map" do
    assert %{recipient: ~c"https://hooks.slack.com/services/[REDACTED]"} =
             Redactor.redact(%{recipient: ~c"https://hooks.slack.com/services/T/B/C"})
  end

  test "redacts a secret in a charlist nested inside a tuple" do
    assert {:missing_or_invalid, :recipient, ~c"https://hooks.slack.com/services/[REDACTED]"} =
             Redactor.redact(
               {:missing_or_invalid, :recipient, ~c"https://hooks.slack.com/services/T/B/C"}
             )
  end

  test "leaves a non-printable list traversed element-by-element" do
    assert [1, 2, 3] = Redactor.redact([1, 2, 3])
  end
end
