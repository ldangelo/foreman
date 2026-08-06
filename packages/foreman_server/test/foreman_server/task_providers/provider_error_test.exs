defmodule ForemanServer.TaskProviders.ProviderErrorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.ProviderError

  test "accepts the 7 allowlisted context keys" do
    assert %ProviderError{
             code: "X",
             message: "m",
             hint: nil,
             retryable?: false,
             context: %{
               id: "1",
               command: "br ready",
               exit_code: 0,
               stderr_byte_count: 0,
               sanitized?: true,
               redacted_fields: [],
               missing_fields: []
             }
           } =
             ProviderError.new("X", "m",
               context: %{
                 id: "1",
                 command: "br ready",
                 exit_code: 0,
                 stderr_byte_count: 0,
                 sanitized?: true,
                 redacted_fields: [],
                 missing_fields: []
               }
             )
  end

  test "rejects non-allowlisted context keys with ArgumentError" do
    assert_raise ArgumentError, fn ->
      ProviderError.new("X", "m", context: %{unknown_key: "x"})
    end
  end

  test "defaults sanitized?, redacted_fields, missing_fields in context when omitted" do
    provider_error = ProviderError.new("X", "m")

    assert provider_error.context.sanitized? == true
    assert provider_error.context.redacted_fields == []
    assert provider_error.context.missing_fields == []
  end

  test "missing_fields round-trips when set" do
    provider_error =
      ProviderError.new("X", "m", context: %{missing_fields: ["priority", "status"]})

    assert provider_error.context.missing_fields == ["priority", "status"]
  end
end
