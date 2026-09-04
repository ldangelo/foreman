defmodule ForemanServer.MCP do
  @moduledoc """
  Anubis MCP server for Foreman — HTTP transport variant.

  Mounted by `ForemanServerWeb.MCPRouter` at `/mcp` via the Streamable HTTP
  transport. All tool wiring — component building, the auth/policy gate, and
  result wrapping — lives in `ForemanServer.MCP.Dispatch` and is shared with
  the stdio transport. This module owns only what is genuinely
  HTTP-specific: the child spec and how the bearer token is recovered from
  the connection.
  """

  use Anubis.Server,
    name: "foreman-mcp",
    version: "1.0.0",
    capabilities: [:tools],
    authorization: [
      validator: {ForemanServer.MCP.Auth, []}
    ]

  alias ForemanServer.MCP.Dispatch
  alias Anubis.Server.Context

  # -------------------------------------------------------------------
  # Tool discovery — runtime filter via Policy.list_tools/1 so write
  # tools are unadvertised when the gate is off (TRD-037 / REQ-020).
  # -------------------------------------------------------------------

  def __components__(:tool), do: Dispatch.components()

  # -------------------------------------------------------------------
  # Supervision / child spec
  # -------------------------------------------------------------------

  @doc "Returns a child spec for the HTTP MCP server (streamable HTTP transport)."
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start:
        {Anubis.Server.Supervisor, :start_link,
         [__MODULE__, Dispatch.transport_opts(opts, :streamable_http)]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc "Returns the configured MCP child spec based on application environment."
  def mcp_child_spec do
    case Application.get_env(:foreman_server, :mcp, [])[:enabled] do
      true -> [child_spec()]
      _ -> []
    end
  end

  # -------------------------------------------------------------------
  # Anubis.Server callbacks
  # -------------------------------------------------------------------

  @doc """
  The `ForemanServer.MCP.Auth` Plug has already allowed-or-halted the request
  before the session starts. It does not assign claims, so `transport_context`
  usually carries none; `handle_tool_call/3` re-verifies regardless.
  """
  @impl Anubis.Server
  def init(_client_info, frame), do: {:ok, frame}

  @doc """
  Handles a tool call for the HTTP transport by recovering the bearer token
  from the connection and delegating to the shared dispatcher.
  """
  @impl Anubis.Server
  def handle_tool_call(name, arguments, frame) do
    Dispatch.call(name, arguments, bearer_token(frame), frame)
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------


  # The only genuinely HTTP-specific piece of tool handling: where the token
  # lives. Anubis puts the request headers on `frame.context.headers`
  # (downcased) — there is no `frame.transport_context`, so the previous
  # match on `%{transport_context: %{auth: ...}}` could never succeed and the
  # token was always dropped. `Dispatch.call/4` fails closed on `nil`,
  # honouring `allow_insecure_local` exactly as the Plug does.
  defp bearer_token(%{context: %Context{headers: headers}}) when is_map(headers) do
    headers |> Map.get("authorization") |> Dispatch.strip_bearer()
  end

  defp bearer_token(_frame), do: nil
end
