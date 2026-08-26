defmodule Mix.Tasks.Foreman.Mcp.Stdio do
  @moduledoc """
  Runs ForemanServer MCP over stdio transport.

  JSON-RPC 2.0 framing on stdin/stdout. All diagnostics are routed to
  Logger's stderr backend so stdout carries protocol bytes only.

  ## TRD-041

  Auth is verified at `initialize` and again before each tool call
  (see `ForemanServer.MCP.Auth`).
  """
  use Mix.Task

  @impl true
  def run(args) do
    # Ensure the application environment is loaded
    Application.put_env(:foreman_server, :mcp, enabled: true)

    # Start the ForemanServer application
    {:ok, _} = Application.ensure_all_started(:foreman_server)
    # Build the child spec with stdio transport
    mcp_spec = ForemanServer.MCP.Stdio.child_spec()

    # Start the MCP supervisor
    {:ok, _pid} = Supervisor.start_link([mcp_spec], strategy: :one_for_one, name: __MODULE__)

    # Block forever — stdio is a long-running session
    Process.sleep(:infinity)
  end
end
