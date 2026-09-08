defmodule ForemanServer.Messaging.Redactor do
  @moduledoc "Redacts messaging secrets from logs, errors, and rendered text."
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> String.replace(~r/bot[0-9]+:[A-Za-z0-9_-]+/, "bot[REDACTED]")
    |> String.replace(~r/\b[0-9]{6,}:[A-Za-z0-9_-]{30,}\b/, "[REDACTED]")
    |> String.replace(
      ~r/https:\/\/hooks\.slack\.com\/services\/[^\s]+/,
      "https://hooks.slack.com/services/[REDACTED]"
    )
    |> String.replace(~r/(https?:\/\/)[^\s\/]+:[^\s@]+@/i, "\\1[REDACTED]@")
    |> String.replace(
      ~r/([?&](?:token|key|secret|webhook|access_token)=)[^\s&]+/i,
      "\\1[REDACTED]"
    )
  end

  def redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
  # A charlist (list of codepoints) is text, not a heterogeneous list —
  # walking it element-by-element hands each integer codepoint to the
  # catch-all clause unchanged, so a printable charlist round-trips through
  # `redact/1` with its secret intact (CodeRabbit review). Detect that case
  # before the generic list clause, redact it as text, and convert back so
  # the return shape still matches the input shape.
  def redact(list) when is_list(list) do
    if List.ascii_printable?(list) do
      list
      |> List.to_string()
      |> redact()
      |> String.to_charlist()
    else
      Enum.map(list, &redact/1)
    end
  end

  # Error reasons are conventionally shaped as tuples embedding the
  # offending raw value (e.g. `{:missing_or_invalid, :recipient, value}`),
  # which can carry the same secrets as a payload map (CodeRabbit review).
  # Recurse into tuple elements instead of returning them untouched.
  def redact(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  end

  def redact(value), do: value
end
