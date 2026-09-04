defmodule ForemanServer.MCP.Stdio do
  @moduledoc """
  Anubis MCP server for Foreman — stdio transport variant.

  Used by `Mix.Tasks.Foreman.Mcp.Stdio` to run the MCP server over
  stdin/stdout instead of HTTP. All tool wiring — component building, the
  auth/policy gate, and result wrapping — lives in
  `ForemanServer.MCP.Dispatch` and is shared with the HTTP transport. This
  module owns only what is genuinely stdio-specific: the child spec and
  recovering the bearer token from the `initialize` request params.
  """

  use Anubis.Server,
    name: "foreman-mcp-stdio",
    version: "1.0.0",
    capabilities: [:tools],
    authorization: [
      validator: {ForemanServer.MCP.Auth, []}
    ]

  alias ForemanServer.MCP.Auth
  alias ForemanServer.MCP.Dispatch
  alias Anubis.MCP.Error
  alias Anubis.Server.Context

  # -------------------------------------------------------------------
  # Tool discovery — runtime filter via Policy.list_tools/1 so write
  # tools are unadvertised when the gate is off (TRD-037 / REQ-020).
  # -------------------------------------------------------------------

  def __components__(:tool), do: Dispatch.components()

  # -------------------------------------------------------------------
  # Supervision / child spec — stdio transport
  # -------------------------------------------------------------------

  @doc "Child spec for stdio transport (transport: :stdio)."
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start:
        {Anubis.Server.Supervisor, :start_link,
         [__MODULE__, Dispatch.transport_opts(opts, :stdio)]},
      type: :supervisor,
      restart: :permanent
    }
  end

  # -------------------------------------------------------------------
  # Anubis.Server callbacks
  # -------------------------------------------------------------------

  @doc """
  Verifies the bearer token from the `initialize` request params.

  For stdio there is no HTTP Authorization header, so the MCP client embeds
  the token as `_meta["authorization"]` ("Bearer <token>"), which Anubis
  surfaces at `frame.context.init_meta`.
  """
  @impl Anubis.Server
  def init(_client_info, frame) do
    # `init_meta` lives on the frame's Context, not on the frame itself; the
    # previous match on `%{init_meta: ...}` could never succeed, so the
    # client's token was always dropped.
    raw_token =
      case frame do
        %{context: %Context{init_meta: %{"authorization" => auth}}} when is_binary(auth) ->
          Dispatch.strip_bearer(auth)

        _ ->
          nil
      end

    case Auth.verify_token(raw_token) do
      :ok ->
        # Stored so handle_tool_call/3 can re-verify per call.
        {:ok, Anubis.Server.Frame.assign(frame, :auth_token, raw_token)}

      {:error, reason} ->
        {:error, %Error{code: "UNAUTHORIZED", message: inspect(reason)}}
    end
  end

  @doc """
  Handles a tool call by recovering the token stored at `initialize` time and
  delegating to the shared dispatcher.
  """
  @impl Anubis.Server
  def handle_tool_call(name, arguments, frame) do
    Dispatch.call(name, arguments, auth_token(frame), frame)
  end

  # `Anubis.Server.Frame` has no `get_assign/2` — reading it raised
  # UndefinedFunctionError on every stdio tool call. Assigns are a plain map.
  defp auth_token(%{assigns: assigns}) when is_map(assigns), do: Map.get(assigns, :auth_token)
  defp auth_token(_frame), do: nil

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------
end
