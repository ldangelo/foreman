defmodule ForemanServer.TaskProviders.BeadsAdapter.CodeMapTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ProviderError

  @source_file Path.expand(
                 "../../../lib/foreman_server/task_providers/beads_adapter_code_map.ex",
                 __DIR__
               )

  test "24-row mapping is deterministic per Foreman.code" do
    rows = mapping_rows()
    assert length(rows) == 24

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

  describe "build_create_provider_error/3 — AC-026 scenarios" do
    test "AC-026-1: VALIDATION + 'title required' hint yields INVALID_TITLE (non-retryable)" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "VALIDATION",
          message: "br rejected the create",
          hint: "title is required and must be non-empty",
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "INVALID_TITLE", retryable?: false} = result
      assert result.message =~ "title"
      assert byte_size(result.hint || "") > 0
    end

    test "AC-026-2: VALIDATION + 'priority must be 0..4' hint yields INVALID_PRIORITY (non-retryable)" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "VALIDATION",
          message: "br rejected the create",
          hint: "priority must be in the inclusive range 0..4",
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "INVALID_PRIORITY", retryable?: false} = result
      assert result.message =~ "priority"
    end

    test "AC-026-3: VALIDATION + 'issue_type must be one of ...' hint yields INVALID_ISSUE_TYPE (non-retryable)" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "VALIDATION",
          message: "br rejected the create",
          hint: "issue_type must be one of task|bug|feature|epic|chore",
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "INVALID_ISSUE_TYPE", retryable?: false} = result
      assert result.message =~ "issue type" or result.message =~ "issue_type"
    end

    test "AC-026-4: DUPLICATE + 'id collision' hint yields DUPLICATE_TASK_ID (non-retryable)" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "DUPLICATE",
          message: "br rejected the create",
          hint: "id collision: task already exists in this database",
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "DUPLICATE_TASK_ID", retryable?: false} = result
    end

    test "AC-026-5: unmapped envelope falls back to CREATE_FAILED with input.retryable? propagated" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "BR_TIMEOUT_QUEUE",
          message: "br create timed out waiting for slot",
          hint: nil,
          retryable?: true
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "CREATE_FAILED", retryable?: true} = result
      assert byte_size(result.message) > 0
      assert byte_size(result.hint || "") > 0
    end

    test "AC-026-5: non-retryable unmapped envelope propagates input.retryable? false" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "BR_PERMISSIONS_DENIED",
          message: "br create permission denied",
          hint: nil,
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "CREATE_FAILED", retryable?: false} = result
    end

    test "explicit CREATE_FAILED envelope from br routes through fallback with input.retryable?" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          code: "CREATE_FAILED",
          message: "br reported CREATE_FAILED",
          hint: nil,
          retryable?: false
        })

      result = CodeMap.build_create_provider_error(input, "br create --db x", 42)

      assert %ProviderError{code: "CREATE_FAILED", retryable?: false} = result
    end
  end

  describe "from_br_envelope/1 tolerates missing optional fields" do
    # Regression: real `br doctor --json` envelopes for sync-merge / preflight
    # codes (`sync_merge_pending_unknown`, etc.) omit `hint` and `retryable?`.
    # `from_br_envelope/1` previously raised `KeyError` on `Map.fetch!`.
    test "missing :hint and :retryable? yields nil defaults without raising" do
      assert %ProviderErrorInput{
               code: "sync_merge_pending_unknown",
               message: "Read-only command is proceeding with automatic sync disabled",
               hint: nil,
               retryable?: nil,
               source: :br_envelope
             } =
               ProviderErrorInput.from_br_envelope(%{
                 "code" => "sync_merge_pending_unknown",
                 "level" => "warning",
                 "message" => "Read-only command is proceeding with automatic sync disabled",
                 "inspection_error" => "database '/tmp/x.db' is missing",
                 "remediation" => "Run `br doctor --json` and restore access before mutating."
               })
    end

    test "build_provider_error/3 accepts an unknown-code envelope missing hint and retryable?" do
      input =
        ProviderErrorInput.from_br_envelope(%{
          "code" => "sync_merge_pending_unknown",
          "message" => "Read-only command is proceeding with automatic sync disabled"
        })

      assert %ProviderError{code: "BR_ERROR_ENVELOPE"} =
               CodeMap.build_provider_error(input, "br doctor --json", 0)
    end
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
