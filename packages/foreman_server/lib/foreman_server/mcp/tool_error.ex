defmodule ForemanServer.MCP.ToolError do
  @moduledoc """
  Typed failure result returned by `ForemanServer.MCP.Tools.call_tool/2`.

  Replaces the bare `%{code: ..., message: ...}` map this contract used to
  carry. The map was unsafe: `wrap_tool_result/3` matched it structurally and
  fell through to a permissive catch-all on any mismatch, which reported the
  failure to the client as a *successful* tool result (`isError: false`). A
  struct makes a malformed failure a compile-time or `KeyError` failure instead
  of a silently-successful response.

  `code` stays a string so the wire format is unchanged (e.g. `"NOT_FOUND"`).
  """

  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: String.t(), message: String.t()}
  @derive Jason.Encoder
  defstruct [:code, :message]
end
