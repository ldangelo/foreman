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
end
