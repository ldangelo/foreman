defmodule ForemanServerWeb.MCPRouter do
  use ForemanServerWeb, :router

  pipeline :mcp do
    plug(:accepts, ["json"])
    plug(ForemanServer.MCP.Auth)
  end

  scope "/mcp" do
    pipe_through(:mcp)

    forward("/", ForemanServerWeb.Plugs.SafeMCPForward,
      inner: Anubis.Server.Transport.StreamableHTTP.Plug,
      server: ForemanServer.MCP
    )
  end
end
