defmodule ForemanServer.MCP do
  @moduledoc """
  Anubis MCP server for Foreman — HTTP transport variant.

  Mounted by `ForemanServerWeb.MCPRouter` at `/mcp` via the Streamable HTTP
  transport.  Tools are defined in `ForemanServer.MCP.Tools` (a plain module
  with `call_tool/2` callbacks) and manually registered as `Anubis.Server.Component.Tool`
  structs so the anubis framework can discover them without requiring
  `use Anubis.Server.Component` on that module.
  """

  use Anubis.Server,
    name: "foreman-mcp",
    version: "1.0.0",
    capabilities: [:tools],
    authorization: [
      validator: {ForemanServer.MCP.Auth, []}
    ]

  alias ForemanServer.MCP.Auth
  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.Tools
  alias Anubis.MCP.Error
  alias Anubis.MCP.Response
  alias Anubis.Server.Component.Tool

  # -------------------------------------------------------------------
  # Tool discovery — runtime filter via Policy.list_tools/1 so write
  # tools are unadvertised when the gate is off (TRD-037 / REQ-020).
  # -------------------------------------------------------------------

  @impl true
  def __components__(:tool) do
    all_schemas = Tools.list_tools()
    authorized_schemas = Policy.list_tools(all_schemas)

    Enum.map(authorized_schemas, fn schema ->
      %Tool{
        name: schema.name,
        title: schema[:title],
        description: schema.description,
        input_schema: schema.inputSchema,
        handler: Tools
      }
    end)
  end
  # -------------------------------------------------------------------
  # Supervision / child spec
  # -------------------------------------------------------------------

  @doc "Returns a child spec for the HTTP MCP server (streamable HTTP transport)."
  def child_spec(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:transport, :streamable_http)
      |> Keyword.put_new(:authorization, authorization_config())

    %{
      id: __MODULE__,
      start: {Anubis.Server.Supervisor, :start_link, [__MODULE__, opts]},
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
  For the HTTP transport, the bearer token was already verified by the
  `ForemanServer.MCP.Auth` Plug before the session starts.  This callback
  provides a second verification checkpoint by checking that
  `transport_context.auth` is present (JWT claims were set by the Plug).
  """
  @impl Anubis.Server
  def init(_client_info, frame) do
    # HTTP: auth claims were set by the Plug after validating the bearer token.
    # Verify they're present (belt-and-suspenders double-check).
    case frame do
      %{transport_context: %{auth: claims}} when is_map(claims) and map_size(claims) > 0 ->
        # Token was verified by Plug; store marker in assigns for handle_tool_call
        verified_frame = Anubis.Server.Frame.assign(frame, :auth_verified, true)
        {:ok, verified_frame}

      _ ->
        # No auth claims — either stdio (which uses init_meta) or a bug.
        # Let handle_tool_call deal with it.
        {:ok, frame}
    end
  end

  @doc """
  Handles a tool call for the HTTP transport.

  Auth was verified at the Plug level before the session started.  This
  callback re-verifies as a belt-and-suspenders measure using the stored
  auth claims (or raw token if available), then checks the write-gate policy
  before delegating to `ForemanServer.MCP.Tools.call_tool/2`.
  """
  @impl Anubis.Server
  def handle_tool_call(name, arguments, frame) do
    # Belt-and-suspenders auth re-verification.
    # For HTTP: we re-verify using the claims from transport_context.auth.
    # The raw token is in claims["token"] if the Plug stored it there.
    auth_ok =
      case frame do
        %{transport_context: %{auth: %{"token" => token}}} when is_binary(token) ->
          Auth.verify_request(token, name, arguments) == :ok

        %{transport_context: %{auth: claims}} when is_map(claims) ->
          # Claims present but no raw token — the Plug already verified.
          # Mark as OK since Plug would have rejected before session started.
          true

        _ ->
          false
      end

    if auth_ok do
      # Policy gate: refuse writes when allow_workflow_writes is disabled
      if Policy.authorized?(name) do
        Tools.call_tool(name, arguments)
        |> wrap_tool_result(name, frame)
      else
        {:error, %Error{code: "POLICY_REFUSED", message: "Tool #{name} is not permitted"}, frame}
      end
    else
      {:error, %Error{code: "UNAUTHORIZED", message: "Authentication required"}, frame}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp authorization_config do
    [validator: {Auth, []}]
  end

  defp wrap_tool_result({:ok, data}, _name, frame) do
    content = [%{"type" => "text", "text" => Jason.encode!(data)}]

    {:reply, %Response{result: %{"content" => content, "isError" => false}, id: "tool_result"},
     frame}
  end

  defp wrap_tool_result({:error, %{code: code, message: message}}, _name, frame) do
    {:error, %Error{code: code, message: message}, frame}
  end

  defp wrap_tool_result(other, _name, frame) do
    content = [%{"type" => "text", "text" => inspect(other)}]

    {:reply, %Response{result: %{"content" => content, "isError" => false}, id: "tool_result"},
     frame}
  end
end
