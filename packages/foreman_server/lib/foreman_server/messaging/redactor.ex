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
  end

  def redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(value), do: value
end
