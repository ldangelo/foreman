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
    "INVALID_TRANSITION_COMMENT" => %{
      foreman_code: "INVALID_TRANSITION_COMMENT",
      retryable?: false
    },
    "ALREADY_CLOSED" => %{foreman_code: "ALREADY_TERMINAL", retryable?: false},
    "INVALID_PRIORITY" => %{foreman_code: "INVALID_PRIORITY", retryable?: false},
    "VALIDATION_FAILED" => %{foreman_code: "VALIDATION_FAILED", retryable?: false},
    "SCHEMA_VALIDATION_FAILED" => %{foreman_code: "SCHEMA_VALIDATION_FAILED", retryable?: false},
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
            source: :br_envelope | :local,
            missing_fields: [String.t()]
          }
    defstruct [:code, :message, :hint, :retryable?, source: :br_envelope, missing_fields: []]

    def from_br_envelope(br_envelope) when is_map(br_envelope) do
      %__MODULE__{
        code: fetch_value(br_envelope, :code),
        message: fetch_value(br_envelope, :message),
        hint: fetch_value(br_envelope, :hint),
        retryable?: fetch_value(br_envelope, :retryable?),
        source: :br_envelope,
        missing_fields: []
      }
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
        _ -> Map.fetch!(map, Atom.to_string(key))
      end
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

  defp build_error(code, message, hint, retryable?, context) do
    ProviderError.new(code, message, hint: hint, retryable?: retryable?, context: context)
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
  end

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

  defp templates_for("VALIDATION_FAILED") do
    {"Beads fail payload failed schema validation.",
     "Refresh the cached schema or re-fetch the Beads payload."}
  end

  defp templates_for("SCHEMA_VALIDATION_FAILED") do
    {"Beads JSON payload failed schema validation.",
     "Refresh the cached schema or re-fetch the Beads payload."}
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
end
