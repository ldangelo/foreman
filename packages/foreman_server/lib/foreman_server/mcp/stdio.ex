defmodule ForemanServer.MCP.Stdio do
  @moduledoc """
  Anubis MCP server for Foreman — stdio transport variant.

  Used by `Mix.Tasks.Foreman.Mcp.Stdio` to run the MCP server over
  stdin/stdout instead of HTTP.  Auth (bearer token) is extracted from the
  `authorization` field of the JSON-RPC `initialize` request params and
  verified in `init/2`, then re-verified before each tool call.
  """

  use Anubis.Server,
    name: "foreman-mcp-stdio",
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
  # Supervision / child spec — stdio transport
  # -------------------------------------------------------------------

  @doc "Child spec for stdio transport (transport: :stdio)."
  def child_spec(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:transport, :stdio)
      |> Keyword.put_new(:authorization, authorization_config())

    %{
      id: __MODULE__,
      start: {Anubis.Server.Supervisor, :start_link, [__MODULE__, opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  # -------------------------------------------------------------------
  # Anubis.Server callbacks
  # -------------------------------------------------------------------

  @doc """
  Verifies the bearer token from the `initialize` request params.

  For stdio there is no HTTP Authorization header, so the MCP client
  embeds the token as `init_meta["authorization"]` ("Bearer <token>" string).
  """
  @impl Anubis.Server
  def init(_client_info, frame) do
    # For stdio, auth comes from the JSON-RPC initialize request params.
    # The MCP client embeds the bearer token as init_meta["authorization"].
    raw_token =
      case frame do
        %{init_meta: %{"authorization" => auth}} when is_binary(auth) ->
          # "Bearer <token>" string from the MCP client
          String.replace_prefix(auth, "Bearer ", "")

        _ ->
          nil
      end

    case Auth.verify_token(raw_token) do
      :ok ->
        # Store the token in frame assigns so handle_tool_call can re-verify
        verified_frame = Anubis.Server.Frame.assign(frame, :auth_token, raw_token)
        {:ok, verified_frame}

      {:error, reason} ->
        {:error, %Error{code: "UNAUTHORIZED", message: inspect(reason)}}
    end
  end

  @doc """
  Handles a tool call.  Re-verifies the stored auth token from the frame
  assigns before delegating to ForemanServer.MCP.Tools.call_tool/2.
  """
  @impl Anubis.Server
  def handle_tool_call(name, arguments, frame) do
    # Re-verify auth from the stored token
    token = Anubis.Server.Frame.get_assign(frame, :auth_token)

    case Auth.verify_request(token, name, arguments) do
      :ok ->
        # Policy gate: refuse writes when allow_workflow_writes is disabled
        if Policy.authorized?(name) do
          Tools.call_tool(name, arguments)
          |> wrap_tool_result(name, frame)
        else
          {:error, %Error{code: "POLICY_REFUSED", message: "Tool #{name} is not permitted"},
           frame}
        end

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
