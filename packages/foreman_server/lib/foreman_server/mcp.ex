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
  alias ForemanServer.MCP.Tools
  alias Anubis.MCP.Error
  alias Anubis.MCP.Response
  alias Anubis.Server.Component.Tool

  # -------------------------------------------------------------------
  # Tool discovery — manually constructed Tool structs from the plain
  # -------------------------------------------------------------------

  @tool_schemas Tools.list_tools()

  @tools Enum.map(@tool_schemas, fn schema ->
           %Tool{
             name: schema.name,
             title: schema[:title],
             description: schema.description,
             input_schema: schema.inputSchema,
             handler: Tools
           }
         end)

  @impl true
  def __components__(:tool), do: @tools

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
  Verifies the bearer token from the transport context after the client
  sends the `initialize` request.
  """
  @impl Anubis.Server
  def init(client_info, frame) do
    auth_claims =
      case frame do
        %{transport_context: %{auth: claims}} -> claims
        _ -> nil
      end

    case Auth.verify_token_from_claims(auth_claims) do
      :ok -> {:ok, frame}
      error -> error
    end
  end

  @doc """
  Handles a tool call.  Delegates to `ForemanServer.MCP.Tools.call_tool/2`
  and wraps the result in an `Anubis.MCP.Response` struct.
  Re-verifies auth before each tool call.
  """
  @impl Anubis.Server
  def handle_tool_call(name, arguments, frame) do
    auth_claims =
      case frame do
        %{transport_context: %{auth: claims}} -> claims
        _ -> nil
      end

    case Auth.verify_request_from_claims(auth_claims, name, arguments) do
      :ok ->
        Tools.call_tool(name, arguments)
        |> wrap_tool_result(name, frame)

      {:error, reason} ->
        {:error, reason, frame}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp authorization_config do
    [validator: {Auth, []}]
  end

  defp wrap_tool_result({:ok, data}, _name, frame) when is_map(data) do
    content = [%{"type" => "text", "text" => Jason.encode!(data)}]

    {:reply, %Response{result: %{"content" => content, "isError" => false}, id: "tool_result"},
     frame}
  end

  defp wrap_tool_result({:ok, data}, _name, frame) do
    content = [%{"type" => "text", "text" => Jason.encode!(data)}]

    {:reply, %Response{result: %{"content" => content, "isError" => false}, id: "tool_result"},
     frame}
  end

  defp wrap_tool_result({:error, %{code: code, message: message}}, _name, frame) do
    {:error, %Error{code: code, message: message}, frame}
  end

  defp wrap_tool_result(other, name, frame) do
    content = [%{"type" => "text", "text" => inspect(other)}]

    {:reply, %Response{result: %{"content" => content, "isError" => false}, id: "tool_result"},
     frame}
  end
end
