defmodule ForemanServer.Agents.McpDiagnostics do
  @moduledoc """
  Bounded diagnostics for malformed MCP responses.

  Captures: endpoint_id, tool_id, correlation_id, error_kind, response_size,
  response_hash. Raw body is NOT captured unless `:debug_policy` includes
  `:include_raw_body`. TRD-2026-4212be7e / MCP-T004 / TRD-051.
  """

  require Logger

  defstruct [
    :endpoint_id,
    :tool_id,
    :correlation_id,
    :error_kind,
    :response_size,
    :response_hash,
    :raw_body_included
  ]

  @doc """
  Capture bounded diagnostics for a malformed MCP response.

  Options:
    * `:debug_policy` - list of debug policy flags. Include `:include_raw_body`
      to record that raw body retention is allowed. The body itself is NOT
      stored in the diagnostic struct.
  """
  def capture(endpoint_id, tool_id, correlation_id, error_kind, response, opts \\ []) do
    size = byte_size(response)
    hash = :crypto.hash(:sha256, response) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    include_raw = Keyword.get(opts, :debug_policy, []) |> Enum.member?(:include_raw_body)

    diag = %__MODULE__{
      endpoint_id: endpoint_id,
      tool_id: tool_id,
      correlation_id: correlation_id,
      error_kind: error_kind,
      response_size: size,
      response_hash: hash,
      raw_body_included: include_raw
    }

    Logger.warning(
      "MCP malformed: ep=#{endpoint_id} tool=#{tool_id} kind=#{error_kind} " <>
        "size=#{size} hash=#{hash} raw=#{include_raw}"
    )

    diag
  end
end
