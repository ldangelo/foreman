defmodule ForemanServer.MCP.Stdio do
  @moduledoc """
  Starts the ForemanServer MCP server with stdio transport.

  This module provides a convenience function for starting the MCP server
  over stdin/stdout (JSON-RPC 2.0 framing).

  Auth is verified at `initialize` and again before each tool call.
  """
  alias ForemanServer.MCP

  @doc """
  Starts the MCP server with stdio transport, linked to the current process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    MCP.child_spec([transport: :stdio] ++ opts)
    |> Supervisor.start_link(strategy: :one_for_one, name: __MODULE__)
  end
end
