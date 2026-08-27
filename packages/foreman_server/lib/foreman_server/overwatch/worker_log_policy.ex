defmodule ForemanServer.Overwatch.WorkerLogPolicy do
  @moduledoc """
  Normalizes worker stdout/stderr before durable persistence.

  Redaction happens before the `WorkerStdout` / `WorkerStderr` event is
  emitted. Control characters are JSON-safe escaped and capture is bounded per
  worker so a noisy provider cannot create an unbounded event stream.
  """

  @default_max_lines 10_000
  @default_max_bytes 5 * 1024 * 1024
  @redacted "[REDACTED]"

  @type counters :: %{lines: non_neg_integer(), bytes: non_neg_integer()}
  @type decision ::
          {:emit, String.t(), counters()}
          | {:drop, %{omitted_lines: pos_integer(), omitted_bytes: non_neg_integer()}}

  @spec default_limits() :: %{max_lines: pos_integer(), max_bytes: pos_integer()}
  def default_limits do
    %{max_lines: @default_max_lines, max_bytes: @default_max_bytes}
  end

  @spec initial_counters() :: counters()
  def initial_counters, do: %{lines: 0, bytes: 0}

  @spec normalize(term(), counters(), keyword()) :: decision()
  def normalize(data, counters \\ initial_counters(), opts \\ []) when is_map(counters) do
    line = data |> stringify() |> redact(Keyword.get(opts, :secrets, [])) |> escape_control_chars()
    bytes = byte_size(line)
    limits = default_limits()
    max_lines = Keyword.get(opts, :max_lines, limits.max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, limits.max_bytes)
    next = %{lines: Map.get(counters, :lines, 0) + 1, bytes: Map.get(counters, :bytes, 0) + bytes}

    if next.lines <= max_lines and next.bytes <= max_bytes do
      {:emit, line, next}
    else
      {:drop, %{omitted_lines: 1, omitted_bytes: bytes}}
    end
  end

  @spec redact(String.t(), [String.t()]) :: String.t()
  def redact(line, secrets \\ []) when is_binary(line) do
    line
    |> redact_configured_secrets(secrets)
    |> String.replace(~r/(?i)(bearer\s+)[A-Za-z0-9._~+\/-]+=*/, "\\1" <> @redacted)
    |> String.replace(~r/(?i)((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,;]+/, "\\1" <> @redacted)
    |> String.replace(~r/-----BEGIN [^-]+PRIVATE KEY-----.*?-----END [^-]+PRIVATE KEY-----/s, @redacted)
  end

  @spec escape_control_chars(String.t()) :: String.t()
  def escape_control_chars(line) when is_binary(line) do
    line
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, fn <<cp>> ->
      "\\u" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
    end)
  end

  defp stringify(data) when is_binary(data), do: data
  defp stringify(data), do: inspect(data)

  defp redact_configured_secrets(line, secrets) do
    Enum.reduce(List.wrap(secrets), line, fn
      secret, acc when is_binary(secret) and secret != "" -> String.replace(acc, secret, @redacted)
      _secret, acc -> acc
    end)
  end
end
