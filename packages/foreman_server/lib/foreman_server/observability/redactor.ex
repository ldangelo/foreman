defmodule ForemanServer.Observability.Redactor do
  @moduledoc """
  Redacts operational log bodies and metadata before any SigNoz/OTel export.

  Unknown metadata keys are dropped. Known diagnostic keys are preserved after
  value sanitization. The denylist intentionally covers credentials, prompts,
  LLM content, DB URLs, auth headers, command output, env-like secrets, and
  user-local paths.
  """

  @whitelisted_keys MapSet.new([
                      :run_id,
                      :task_id,
                      :project_id,
                      :workflow_name,
                      :phase_index,
                      :phase_name,
                      :phase_type,
                      :worker_id,
                      :operation,
                      :outcome,
                      :reason,
                      :status,
                      :module,
                      :function,
                      :line,
                      :branch,
                      :base_branch,
                      :head_branch,
                      :pr_url,
                      :exit_code,
                      :duration_ms,
                      :retry_count,
                      :endpoint_host,
                      :endpoint_port,
                      :trace_id,
                      :span_id,
                      :source
                    ])

  @sensitive_key ~r/(secret|token|password|credential|authorization|api[_-]?key|prompt|llm|database_url|output|env|header)/i
  @db_url ~r/(postgres(?:ql)?:\/\/)[^\s]+/i
  @auth_header ~r/(authorization\s*[:=]\s*)(bearer\s+)?[^\s,;]+/i
  @home_path ~r/(\/Users\/|\/home\/)[^\s,;:]+/
  @key_value_secret ~r/([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|DATABASE_URL)[A-Z0-9_]*\s*=\s*)[^\s]+/i

  @spec redact_message(term()) :: String.t()
  def redact_message(message) do
    message
    |> safe_to_string()
    |> redact_text()
  end

  @spec redact_metadata(map() | keyword() | nil) :: map()
  def redact_metadata(nil), do: %{}

  def redact_metadata(metadata) when is_list(metadata) do
    metadata
    |> Enum.into(%{})
    |> redact_metadata()
  rescue
    _ -> %{}
  end

  def redact_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      atom_key = normalize_key(key)

      cond do
        is_nil(atom_key) -> acc
        sensitive_key?(key) -> acc
        MapSet.member?(@whitelisted_keys, atom_key) -> Map.put(acc, atom_key, redact_value(value))
        true -> acc
      end
    end)
  end

  def redact_metadata(_), do: %{}

  @spec whitelisted_keys() :: [atom()]
  def whitelisted_keys, do: MapSet.to_list(@whitelisted_keys)

  defp redact_value(value) when is_binary(value), do: redact_text(value)
  defp redact_value(nil), do: nil
  defp redact_value(value) when is_atom(value) or is_number(value) or is_boolean(value), do: value
  defp redact_value(value), do: value |> inspect(limit: 20, printable_limit: 200) |> redact_text()

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key, to_string(key))

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_key(_), do: nil

  defp redact_text(text) do
    text
    |> String.replace(@db_url, "\\1[REDACTED]")
    |> String.replace(@auth_header, "\\1[REDACTED]")
    |> String.replace(@key_value_secret, "\\1[REDACTED]")
    |> String.replace(@home_path, "/[REDACTED_PATH]")
  end

  defp safe_to_string({:string, chardata}), do: IO.iodata_to_binary(chardata)

  defp safe_to_string({:report, report}) do
    report |> redact_report() |> inspect(limit: 20, printable_limit: 500)
  end

  defp safe_to_string(chardata) when is_list(chardata), do: IO.iodata_to_binary(chardata)
  defp safe_to_string(binary) when is_binary(binary), do: binary
  defp safe_to_string(other), do: inspect(other, limit: 20, printable_limit: 500)

  # Structured Logger `:report` terms (maps or proplists — OTP crash/progress
  # reports use both) used to reach `inspect/2` raw: `redact_text/1` only
  # scrubs value-shaped patterns (DB URLs, `Authorization: ...`,
  # `UPPER_NAME=value`), so a report field like `%{password: "hunter2"}`
  # rendered as `password: "hunter2"` in the inspected text and none of
  # those regexes matched a lowercase, colon-separated key — the secret
  # shipped in the OTLP body verbatim (CWE-532). Walk the term first and
  # blank out any key matching `sensitive_key?/1` before it is ever
  # stringified. Depth is bounded (crash reports are shallow in practice);
  # `redact_text/1` still runs on the final inspected string afterward as a
  # second pass over any value-shaped secret left under a non-sensitive key.
  @report_redact_max_depth 6

  defp redact_report(term, depth \\ 0)

  defp redact_report(%{} = map, depth) when depth < @report_redact_max_depth do
    Map.new(map, fn {key, value} -> {key, redact_report_field(key, value, depth)} end)
  end

  defp redact_report(list, depth) when is_list(list) and depth < @report_redact_max_depth do
    Enum.map(list, fn
      {key, value} -> {key, redact_report_field(key, value, depth)}
      other -> redact_report(other, depth + 1)
    end)
  end

  # A map or list still nested at/beyond the depth limit would otherwise
  # fall through unredacted (CWE-532: the recursive redaction clauses above
  # only fire while depth < @report_redact_max_depth), silently shipping any
  # sensitive key below the limit verbatim. Truncate instead of passing the
  # raw subtree through (CodeRabbit review).
  defp redact_report(%{} = _map, _depth), do: "[REDACTED:MAX_DEPTH]"
  defp redact_report(list, _depth) when is_list(list), do: "[REDACTED:MAX_DEPTH]"
  defp redact_report(other, _depth), do: other

  defp redact_report_field(key, value, depth) do
    if (is_atom(key) or is_binary(key)) and sensitive_key?(key) do
      "[REDACTED]"
    else
      redact_report(value, depth + 1)
    end
  end
end
