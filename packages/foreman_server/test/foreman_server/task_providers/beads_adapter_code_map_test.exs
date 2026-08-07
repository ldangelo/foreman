defmodule ForemanServer.TaskProviders.BeadsAdapter.CodeMapTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ProviderError

  @source_file Path.expand(
                 "../../../lib/foreman_server/task_providers/beads_adapter_code_map.ex",
                 __DIR__
               )

  test "20-row mapping is deterministic per Foreman.code" do
    rows = mapping_rows()
    assert length(rows) == 20

    Enum.each(rows, fn %{br_code: br_code, foreman_code: foreman_code, retryable?: retryable?} ->
      input =
        ProviderErrorInput.from_local(
          br_code,
          "original envelope message",
          "original envelope hint",
          not retryable?
        )

      first = CodeMap.build_provider_error(input, "br issue show #{br_code}", 17)
      second = CodeMap.build_provider_error(input, "br issue show #{br_code}", 17)

      assert %ProviderError{code: ^foreman_code, retryable?: ^retryable?} = first
      assert second.code == first.code
      assert second.retryable? == first.retryable?
      assert byte_size(first.message) > 0
      refute first.message == "original envelope message"
    end)
  end

  test "DATABASE_NOT_FOUND row maps to ProviderError{code: DATABASE_NOT_FOUND, retryable?: false}" do
    assert %ProviderError{code: "DATABASE_NOT_FOUND", retryable?: false, message: message} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 "DATABASE_NOT_FOUND",
                 "ignored envelope message",
                 "ignored envelope hint",
                 true
               ),
               "br db open",
               23
             )

    assert byte_size(message) > 0
  end

  test "INVALID_PRIORITY row maps to ProviderError{code: INVALID_PRIORITY, retryable?: false}" do
    assert %ProviderError{code: "INVALID_PRIORITY", retryable?: false, message: message} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 "INVALID_PRIORITY",
                 "ignored envelope message",
                 "ignored envelope hint",
                 true
               ),
               nil,
               0
             )

    assert byte_size(message) > 0
  end

  test "INVALID_TASK_ID row maps to ProviderError{code: INVALID_TASK_ID, retryable?: false}" do
    assert %ProviderError{code: "INVALID_TASK_ID", retryable?: false, message: message} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 "INVALID_TASK_ID",
                 "ignored envelope message",
                 "ignored envelope hint",
                 true
               ),
               nil,
               0
             )

    assert byte_size(message) > 0
  end

  test "ALREADY_OPEN row maps to ALREADY_TERMINAL and remains non-retryable" do
    provider_error =
      CodeMap.build_provider_error(
        ProviderErrorInput.from_local(
          "ALREADY_OPEN",
          "ignored envelope message",
          "ignored envelope hint",
          true
        ),
        "br update",
        17
      )

    assert is_struct(provider_error, ProviderError)
    assert provider_error.code == "ALREADY_TERMINAL"
    assert provider_error.retryable? == false
    assert byte_size(provider_error.message) > 0
  end

  test "DEPENDENCY_CYCLE row maps to ProviderError{code: DEPENDENCY_CYCLE, retryable?: false}" do
    assert %ProviderError{code: "DEPENDENCY_CYCLE", retryable?: false, message: message} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 "DEPENDENCY_CYCLE",
                 "ignored envelope message",
                 "ignored envelope hint",
                 true
               ),
               "br dep add",
               17
             )

    assert byte_size(message) > 0
  end

  test "DEPENDENCY_EXISTS row maps to ProviderError{code: DEPENDENCY_EXISTS, retryable?: false}" do
    assert %ProviderError{code: "DEPENDENCY_EXISTS", retryable?: false, message: message} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 "DEPENDENCY_EXISTS",
                 "ignored envelope message",
                 "ignored envelope hint",
                 true
               ),
               "br dep add",
               17
             )

    assert byte_size(message) > 0
  end

  test "CLAIMED_BY_OTHER only surfaces current_assignee presence" do
    assert %ProviderError{
             code: "CLAIMED_BY_OTHER",
             retryable?: true,
             context: %{current_assignee_present?: true, redacted_fields: ["current_assignee"]}
           } =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_br_envelope(%{
                 code: "CLAIMED_BY_OTHER",
                 message: "raw envelope message",
                 hint: "raw envelope hint",
                 retryable?: false,
                 current_assignee: "secret-owner"
               }),
               "br update --claim bead-102b",
               19
             )

    refute inspect(
             CodeMap.build_provider_error(
               ProviderErrorInput.from_br_envelope(%{
                 code: "CLAIMED_BY_OTHER",
                 message: "raw envelope message",
                 hint: "raw envelope hint",
                 retryable?: false,
                 current_assignee: "secret-owner"
               }),
               "br update --claim bead-102b",
               19
             )
           ) =~ "secret-owner"
  end

  test "build_provider_error/3 is the only construction site (no direct struct construction)" do
    source = code_map_source()
    assert Code.ensure_loaded?(CodeMap)
    assert function_exported?(CodeMap, :build_provider_error, 3)
    assert Regex.scan(~r/ProviderError\.new\s*\(/, source) |> length() == 1
    refute Regex.match?(~r/struct\s*\(\s*ProviderError\s*,/, source)
    refute Regex.match?(~r/%(?:[A-Za-z0-9_.]+\.)?ProviderError\s*\{/, source)
  end

  test "unknown br.code preserves br.retryable and surfaces the raw br.code" do
    Enum.each([true, false], fn retryable? ->
      assert %ProviderError{
               code: "BR_ERROR_ENVELOPE",
               message: "UNKNOWN_BR_CODE",
               hint: nil,
               retryable?: ^retryable?
             } =
               CodeMap.build_provider_error(
                 ProviderErrorInput.from_br_envelope(%{
                   code: "UNKNOWN_BR_CODE",
                   message: "raw envelope message",
                   hint: "raw envelope hint",
                   retryable?: retryable?
                 }),
                 nil,
                 0
               )
    end)
  end

  test "template strings do not contain br.code interpolation" do
    Enum.each(mapping_rows(), fn %{foreman_code: foreman_code} ->
      block = template_block_for(foreman_code)
      assert is_binary(block), "Missing templates_for/1 block for #{foreman_code}"
      refute String.contains?(block, "br.code")
      refute Regex.match?(~r/#\{[^}]*\}/, block)
    end)
  end

  test "CodeMap compiles" do
    assert Code.ensure_loaded?(CodeMap)
  end

  defp code_map_source, do: File.read!(@source_file)

  defp mapping_rows do
    Regex.scan(
      ~r/"(?<br_code>[^"]+)"\s*=>\s*%\{\s*foreman_code:\s*"(?<foreman_code>[^"]+)",\s*retryable\?:\s*(?<retryable>true|false)(?:,\s*redacted_fields:\s*\[[^\]]*\])?\s*\}/s,
      code_map_source(),
      capture: :all_names
    )
    |> Enum.map(fn [br_code, foreman_code, retryable] ->
      %{br_code: br_code, foreman_code: foreman_code, retryable?: retryable == "true"}
    end)
  end

  defp template_block_for(foreman_code) do
    pattern =
      Regex.compile!(
        "defp templates_for\\(\\\"#{Regex.escape(foreman_code)}\\\"\\) do(?<body>.*?)\\n  end",
        "ms"
      )

    case Regex.named_captures(pattern, code_map_source()) do
      %{"body" => body} -> body
      _ -> nil
    end
  end
end
