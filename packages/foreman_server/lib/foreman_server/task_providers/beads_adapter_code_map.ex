defmodule ForemanServer.TaskProviders.BeadsAdapter.CodeMap do
  @moduledoc "Builds typed provider errors from Beads adapter inputs."

  alias __MODULE__.ProviderErrorInput
  alias ForemanServer.TaskProviders.ProviderError

  @mapping %{
    "DATABASE_NOT_FOUND" => %{foreman_code: "DATABASE_NOT_FOUND", retryable?: false},
    "NOT_CLAIMABLE" => %{foreman_code: "NOT_CLAIMABLE", retryable?: false},
    "CLAIMED_BY_OTHER" => %{
      foreman_code: "CLAIMED_BY_OTHER",
      retryable?: true,
      redacted_fields: ["current_assignee"]
    },
    "ISSUE_NOT_FOUND" => %{foreman_code: "ISSUE_NOT_FOUND", retryable?: false},
    "INVALID_TASK_ID" => %{foreman_code: "INVALID_TASK_ID", retryable?: false},
    "INVALID_PRIORITY" => %{foreman_code: "INVALID_PRIORITY", retryable?: false},
    "INVALID_TITLE" => %{foreman_code: "INVALID_TITLE", retryable?: false},
    "INVALID_ISSUE_TYPE" => %{foreman_code: "INVALID_ISSUE_TYPE", retryable?: false},
    "DUPLICATE_TASK_ID" => %{foreman_code: "DUPLICATE_TASK_ID", retryable?: false},
    "CREATE_FAILED" => %{foreman_code: "CREATE_FAILED", retryable?: true},
    "INVALID_TRANSITION_COMMENT" => %{
      foreman_code: "INVALID_TRANSITION_COMMENT",
      retryable?: false
    },
    "ALREADY_CLOSED" => %{foreman_code: "ALREADY_TERMINAL", retryable?: false},
    "ALREADY_OPEN" => %{foreman_code: "ALREADY_TERMINAL", retryable?: false},
    "DEPENDENCY_CYCLE" => %{foreman_code: "DEPENDENCY_CYCLE", retryable?: false},
    "DEPENDENCY_EXISTS" => %{foreman_code: "DEPENDENCY_EXISTS", retryable?: false},
    "VALIDATION_FAILED" => %{foreman_code: "VALIDATION_FAILED", retryable?: false},
    "SCHEMA_VALIDATION_FAILED" => %{foreman_code: "SCHEMA_VALIDATION_FAILED", retryable?: false},
    # br preflight / command workspace errors (nested %{"error" => %{...}} envelopes)
    "NOT_IN_WORKSPACE" => %{foreman_code: "NOT_IN_WORKSPACE", retryable?: false},
    "WORKSPACE_NOT_FOUND" => %{foreman_code: "WORKSPACE_NOT_FOUND", retryable?: false},
    # Generic / internal sentinel
    "BR_ERROR_ENVELOPE" => %{foreman_code: "BR_ERROR_ENVELOPE", retryable?: false},
    "BR_TIMEOUT_QUEUE" => %{foreman_code: "BR_TIMEOUT_QUEUE", retryable?: true},
    "BR_TIMEOUT_SUBPROCESS" => %{foreman_code: "BR_TIMEOUT_SUBPROCESS", retryable?: true},
    "BR_PERMISSIONS_DENIED" => %{foreman_code: "BR_PERMISSIONS_DENIED", retryable?: false},
    "BR_DATABASE_LOCKED" => %{foreman_code: "BR_DATABASE_LOCKED", retryable?: true},
    "BR_PARSE_ERROR" => %{foreman_code: "BR_PARSE_ERROR", retryable?: false},
    "BR_CONTRACT_MISMATCH" => %{foreman_code: "BR_CONTRACT_MISMATCH", retryable?: false}
  }

  defmodule ProviderErrorInput do
    @moduledoc false

    @enforce_keys [:code, :message, :hint, :retryable?, :source, :missing_fields]
    @type t :: %__MODULE__{
            code: String.t() | atom(),
            message: String.t(),
            hint: String.t() | nil,
            retryable?: boolean(),
            current_assignee_present?: boolean() | nil,
            source: :br_envelope | :local,
            missing_fields: [String.t()]
          }
    defstruct [
      :code,
      :message,
      :hint,
      :retryable?,
      :current_assignee_present?,
      source: :br_envelope,
      missing_fields: []
    ]

    def from_br_envelope(br_envelope) when is_map(br_envelope) do
      # br 0.2.22 returns nested `%{"error" => %{...}}` envelopes for preflight
      # and some command errors. The fix for pre-existing KeyError on missing
      # keys (UA14) used fetch_value/2 which safely returns nil — but that
      # silently discards the entire inner error when the data lives one level
      # deeper. This unwrap recovers the actual error detail. Retain the
      # existing flat-envelope path so documented flat shapes still work.
      inner =
        case br_envelope do
          %{error: nested} when is_map(nested) -> nested
          %{"error" => nested} when is_map(nested) -> nested
          _ -> br_envelope
        end

      %__MODULE__{
        code: fetch_value(inner, :code),
        message: fetch_value(inner, :message),
        hint: fetch_value(inner, :hint),
        # br uses "retryable" (no ?); the schema uses :retryable? (with ?).
        # Normalize: pull "retryable"/:retryable first; default to nil rather
        # than the :retryable? key which won't exist in either envelope shape.
        retryable?: fetch_retryable(inner),
        current_assignee_present?: current_assignee_present(inner),
        source: :br_envelope,
        missing_fields: []
      }
    end

    # Normalize "retryable"/:retryable → boolean, covering br's actual "retryable"
    # (no ?), the schema's :retryable? (with ?), and the string forms of both.
    defp fetch_retryable(inner) do
      case inner do
        %{retryable: value} when is_boolean(value) -> value
        %{"retryable" => value} when is_boolean(value) -> value
        %{retryable?: value} when is_boolean(value) -> value
        %{"retryable?" => value} when is_boolean(value) -> value
        _ -> nil
      end
    end

    def from_local(code, message, hint, retryable?, missing_fields \\ []) do
      %__MODULE__{
        code: code,
        message: message,
        hint: hint,
        retryable?: retryable?,
        source: :local,
        missing_fields: missing_fields
      }
    end

    defp fetch_value(map, key) do
      case map do
        %{^key => value} -> value
        _ -> Map.get(map, Atom.to_string(key))
      end
    end

    defp current_assignee_present(br_envelope) do
      Map.has_key?(br_envelope, :current_assignee) or
        Map.has_key?(br_envelope, "current_assignee")
    end
  end

  @spec build_provider_error(ProviderErrorInput.t(), String.t() | nil, non_neg_integer()) ::
          ProviderError.t()
  def build_provider_error(%ProviderErrorInput{} = input, command, stderr_byte_count)
      when (is_binary(command) or is_nil(command)) and
             is_integer(stderr_byte_count) and stderr_byte_count >= 0 do
    normalized_input = %{input | code: normalize_code(input.code)}

    if Map.has_key?(@mapping, normalized_input.code) do
      translate(normalized_input, command, stderr_byte_count)
    else
      translate_unknown(normalized_input, command, stderr_byte_count)
    end
  end

  @doc """
  Translates a `br create` error envelope into a typed Foreman provider error.

  Applies the create-specific classifier (mapping `{code, hint}` combinations
  to the four dedicated create Foreman codes) before dispatching to the
  translator. Only `INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`,
  and `DUPLICATE_TASK_ID` go through `translate/3` (using the row's
  `retryable?`). Every other create failure — including explicit
  `"CREATE_FAILED"` envelopes and any other upstream code — falls through to
  `translate_create_failed/3`, which yields `CREATE_FAILED` with
  `retryable?` propagated verbatim from `input.retryable?` (per
  PRD-2026-48f7b420 REQ-008-2 unknown-code policy).
  """
  @spec build_create_provider_error(ProviderErrorInput.t(), String.t() | nil, non_neg_integer()) ::
          ProviderError.t()
  def build_create_provider_error(%ProviderErrorInput{} = input, command, stderr_byte_count)
      when (is_binary(command) or is_nil(command)) and
             is_integer(stderr_byte_count) and stderr_byte_count >= 0 do
    classified_input = classify_create_error(input)
    normalized_input = %{classified_input | code: normalize_code(classified_input.code)}

    if create_known_code?(normalized_input.code) do
      translate(normalized_input, command, stderr_byte_count)
    else
      translate_create_failed(normalized_input, command, stderr_byte_count)
    end
  end

  defp translate(%ProviderErrorInput{code: code} = input, command, stderr_byte_count) do
    row = Map.fetch!(@mapping, code)
    {message, hint} = templates_for(row.foreman_code)

    build_error(
      row.foreman_code,
      message,
      hint,
      row.retryable?,
      build_context(input, command, stderr_byte_count, Map.get(row, :redacted_fields, []))
    )
  end

  defp translate_unknown(%ProviderErrorInput{} = input, command, stderr_byte_count) do
    build_error(
      "BR_ERROR_ENVELOPE",
      normalize_code(input.code),
      nil,
      input.retryable?,
      build_context(input, command, stderr_byte_count, [])
    )
  end

  # Coerce nil (absent retryable in envelope) to false — ProviderError.retryable?
  # is a boolean field; nil would bypass Keyword.get's default and stay nil in
  # the struct, violating the typed contract.
  defp build_error(code, message, hint, retryable?, context)
       when is_boolean(retryable?) do
    ProviderError.new(code, message, hint: hint, retryable?: retryable?, context: context)
  end

  defp build_error(code, message, hint, _retryable?, context) do
    # nil (absent) or non-boolean → default to false, preserving other fields.
    ProviderError.new(code, message, hint: hint, retryable?: false, context: context)
  end

  defp build_context(input, command, stderr_byte_count, redacted_fields) do
    %{
      id: normalize_id(input.code),
      command: command,
      exit_code: nil,
      stderr_byte_count: stderr_byte_count,
      sanitized?: true,
      redacted_fields: redacted_fields,
      missing_fields: input.missing_fields
    }
    |> maybe_put_current_assignee_present(input.current_assignee_present?)
  end

  defp maybe_put_current_assignee_present(context, true),
    do: Map.put(context, :current_assignee_present?, true)

  defp maybe_put_current_assignee_present(context, _other), do: context

  defp normalize_code(code) when is_binary(code), do: code
  defp normalize_code(code) when is_atom(code), do: Atom.to_string(code)

  defp normalize_id(nil), do: nil
  defp normalize_id(code) when is_binary(code), do: code
  defp normalize_id(code) when is_atom(code), do: Atom.to_string(code)

  defp templates_for("DATABASE_NOT_FOUND") do
    {"Configured Beads database was not found.",
     "Verify the configured database path before retrying."}
  end

  defp templates_for("NOT_CLAIMABLE") do
    {"Issue cannot be claimed in its current state.",
     "Refresh the issue state before retrying the claim."}
  end

  defp templates_for("CLAIMED_BY_OTHER") do
    {"Issue is already claimed by another assignee.",
     "Release or reassign the issue before retrying the claim."}
  end

  defp templates_for("ISSUE_NOT_FOUND") do
    {"Requested issue was not found.", "Verify the issue identifier before retrying."}
  end

  defp templates_for("INVALID_TASK_ID") do
    {"Issue identifier must be a non-empty string.",
     "Pass a non-empty Beads issue identifier before retrying."}
  end

  defp templates_for("INVALID_TRANSITION_COMMENT") do
    {"Transition comment must be a non-empty string.",
     "Pass :transition_comment or provide both :run_id and :artifact_path."}
  end

  defp templates_for("ALREADY_TERMINAL") do
    {"Issue is already closed.", "Treat duplicate completion as an idempotent success."}
  end

  defp templates_for("INVALID_PRIORITY") do
    {"Issue priority must be between 0 and 4.",
     "Pass a Beads priority level in the inclusive range 0..4."}
  end

  defp templates_for("DEPENDENCY_CYCLE") do
    {"Dependency edge would create a cycle.",
     "Choose a dependency that does not reference the issue itself or any of its descendants."}
  end

  defp templates_for("DEPENDENCY_EXISTS") do
    {"Dependency edge already exists.",
     "Treat duplicate dependency insertion as an idempotent no-op or remove the existing edge first."}
  end

  defp templates_for("VALIDATION_FAILED") do
    {"Beads updated issue payload failed schema validation.",
     "Refresh the cached schema or re-fetch the Beads payload."}
  end
  defp templates_for("SCHEMA_VALIDATION_FAILED") do
    {"Beads JSON payload failed schema validation.",
     "Refresh the cached schema or re-fetch the Beads payload."}
  end

  defp templates_for("NOT_IN_WORKSPACE") do
    {"Current directory is not inside a Beads workspace.",
     "Run br init or cd into an initialized workspace."}
  end

  defp templates_for("WORKSPACE_NOT_FOUND") do
    {"No Beads workspace found at the configured path.",
     "Run br init or br clone to initialize a workspace."}
  end

  defp templates_for("BR_ERROR_ENVELOPE") do
    {"Beads CLI returned an unmapped error envelope.",
     "Update the adapter mapping or install a supported Beads CLI version."}
  end

  defp templates_for("BR_TIMEOUT_QUEUE") do
    {"Beads command timed out while waiting for a concurrency slot.",
     "Retry after the adapter queue drains."}
  end

  defp templates_for("BR_TIMEOUT_SUBPROCESS") do
    {"Beads command timed out while the subprocess was running.",
     "Retry the command after checking Beads responsiveness."}
  end

  defp templates_for("BR_PERMISSIONS_DENIED") do
    {"Beads command could not access the requested resource.",
     "Verify filesystem permissions and adapter credentials before retrying."}
  end

  defp templates_for("BR_DATABASE_LOCKED") do
    {"Beads database is locked.", "Retry after the current database lock is released."}
  end

  defp templates_for("BR_PARSE_ERROR") do
    {"Beads output could not be parsed.",
     "Check the Beads output format or refresh the CLI contract cache."}
  end

  defp templates_for("BR_CONTRACT_MISMATCH") do
    {"Beads CLI contract does not match the adapter expectations.",
     "Update the adapter or install a supported Beads CLI version."}
  end

  defp templates_for("INVALID_TITLE") do
    {"Issue title must be a non-empty string.",
     "Pass a non-empty title before retrying the create operation."}
  end

  defp templates_for("INVALID_ISSUE_TYPE") do
    {"Issue type must be one of the supported Beads issue types.",
     "Pass a supported issue_type before retrying the create operation."}
  end

  defp templates_for("DUPLICATE_TASK_ID") do
    {"Beads rejected the create as a duplicate task identifier.",
     "Pass a unique task identifier or reconcile with the existing issue."}
  end

  defp templates_for("CREATE_FAILED") do
    {"Beads create operation failed with an unmapped envelope.",
     "Retry the create operation per the upstream retryable flag."}
  end

  # The four dedicated create-validation/duplicate Foreman codes route through
  # `translate/3` (using the row's `retryable?`). All other create failures —
  # including explicit `"CREATE_FAILED"` envelopes and any other upstream
  # code — route through `translate_create_failed/3` so `input.retryable?` is
  # propagated verbatim.
  @create_known_codes ~w(INVALID_TITLE INVALID_PRIORITY INVALID_ISSUE_TYPE DUPLICATE_TASK_ID)

  defp create_known_code?(code) when is_binary(code), do: code in @create_known_codes
  defp create_known_code?(_), do: false

  defp classify_create_error(%ProviderErrorInput{} = input) do
    case {normalize_code(input.code), hint_string(input)} do
      {"VALIDATION", hint} when is_binary(hint) ->
        cond do
          title_hint?(hint) -> %{input | code: "INVALID_TITLE"}
          priority_hint?(hint) -> %{input | code: "INVALID_PRIORITY"}
          issue_type_hint?(hint) -> %{input | code: "INVALID_ISSUE_TYPE"}
          true -> input
        end

      {"DUPLICATE", hint} when is_binary(hint) ->
        if duplicate_hint?(hint) do
          %{input | code: "DUPLICATE_TASK_ID"}
        else
          input
        end

      _ ->
        input
    end
  end

  defp translate_create_failed(%ProviderErrorInput{} = input, command, stderr_byte_count) do
    {message, hint} = templates_for("CREATE_FAILED")

    build_error(
      "CREATE_FAILED",
      message,
      hint,
      input.retryable?,
      build_context(input, command, stderr_byte_count, [])
    )
  end

  defp hint_string(%ProviderErrorInput{hint: hint}) when is_binary(hint), do: hint
  defp hint_string(_), do: nil

  defp title_hint?(hint), do: hint =~ ~r/title/i
  defp priority_hint?(hint), do: hint =~ ~r/priority/i
  defp issue_type_hint?(hint), do: hint =~ ~r/issue_type|issue type/i
  defp duplicate_hint?(hint), do: hint =~ ~r/id|identifier|collision/i
end
