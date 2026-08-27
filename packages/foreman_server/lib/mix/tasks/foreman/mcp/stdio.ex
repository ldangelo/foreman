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
  def run(_args) do
    # Merge, never replace. This previously did
    # `Application.put_env(:foreman_server, :mcp, enabled: true)`, which
    # discarded every other key the environment config had set — including
    # `allow_insecure_local: true`. With that key gone, the authorization
    # validator was attached without the `resource` and
    # `authorization_servers` that Anubis's Peri schema requires, so
    # `Anubis.Server.Authorization.parse_config!/1` raised during boot and the
    # whole application failed to start. The MCP client saw only
    # "Transport closed".
    #
    # `enabled: false` keeps the application from also starting the HTTP MCP
    # child: this task owns a single stdio session and starts that transport
    # itself, just below.
    mcp_config =
      :foreman_server
      |> Application.get_env(:mcp, [])
      |> Keyword.put(:enabled, false)

    Application.put_env(:foreman_server, :mcp, mcp_config)

    {:ok, _} = Application.ensure_all_started(:foreman_server)

    {:ok, _pid} =
      Supervisor.start_link([ForemanServer.MCP.Stdio.child_spec()],
        strategy: :one_for_one,
        name: __MODULE__
      )

    # Block forever — stdio is a long-running session.
    Process.sleep(:infinity)
  end
end
