defmodule ForemanServer.MCP.Dispatch do
  @moduledoc """
  Transport-independent MCP wiring shared by `ForemanServer.MCP` (Streamable
  HTTP) and `ForemanServer.MCP.Stdio`.

  Both transports previously carried byte-identical copies of component
  building, the auth/policy gate, and result wrapping. Three separate defects
  had to be fixed in both files, and the stdio copy was missed on the first
  pass. The only genuine difference between the transports is *where the bearer
  token comes from*, so that is the only thing they still implement
  themselves — they pass it into `call/4`.

  ## Anubis contract notes (each one was a live crash)

  - `%Tool{handler: nil}` is required. `Anubis.Server.Handlers.Tools.forward_to/4`
    only routes to `server.handle_tool_call/3` when `handler` is nil; a non-nil
    handler makes Anubis call `handler.execute/2`, which does not exist here and
    would bypass the auth/policy gate.
  - `validate_input` must be set. When it is nil,
    `Anubis.Server.Handlers.Tools.validate_params/3` returns `{:ok, %{}}` and
    **discards the caller's arguments entirely**, so every tool requiring a
    named argument falls through to the `call_tool/2` catch-all.
  - Replies must be `Anubis.Server.Response`, not `Anubis.MCP.Response`. The
    handler pattern-matches the former; the latter raises `CaseClauseError`.
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Response
  alias ForemanServer.MCP.Auth
  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.MCP.Tools

  @doc """
  Builds the `Anubis.Server.Component.Tool` structs for every tool the current
  policy permits.
  """
  @spec components() :: [Tool.t()]
  def components do
    Tools.list_tools()
    |> Policy.list_tools()
    |> Enum.map(fn schema ->
      %Tool{
        name: schema.name,
        title: schema[:title],
        description: schema.description,
        input_schema: schema.inputSchema,
        handler: nil,
        validate_input: input_validator(schema.inputSchema)
      }
    end)
  end

  @doc """
  Runs a tool call behind the auth and policy gates.

  `token` is the transport-supplied bearer token (or `nil`). It is verified
  through `Auth.verify_request/3`, which fails closed: with no token it returns
  `:ok` only when `allow_insecure_local: true` is configured.
  """
  @spec call(String.t(), map(), String.t() | nil, term()) ::
          {:reply, Response.t(), term()} | {:error, Error.t(), term()}
  def call(name, arguments, token, frame) do
    cond do
      Auth.verify_request(token, name, arguments) != :ok ->
        {:error, error("UNAUTHORIZED", "Authentication required"), frame}

      not Policy.authorized?(name) ->
        {:error, error("POLICY_REFUSED", "Tool #{name} is not permitted"), frame}

      true ->
        name |> Tools.call_tool(arguments) |> wrap(frame)
    end
  end

  @doc """
  Strips the `Bearer ` prefix from an `Authorization` header value.

  Shared by both transports: HTTP reads the header off
  `frame.context.headers`, stdio reads it from
  `frame.context.init_meta["authorization"]`.
  """
  @spec strip_bearer(String.t() | nil) :: String.t() | nil
  def strip_bearer(nil), do: nil

  def strip_bearer(value) when is_binary(value) do
    case String.trim(String.replace_prefix(value, "Bearer ", "")) do
      "" -> nil
      token -> token
    end
  end

  @doc """
  Builds the `Anubis.Server.Supervisor` options for a transport.

  `transport` is `:stdio` or `{:streamable_http, opts}`; the HTTP transport MUST
  carry `start: true` (see `ForemanServer.MCP.child_spec/1`: Anubis otherwise
  guesses whether an HTTP server is running and `:ignore`s the whole server on
  every boot that is not `mix phx.server`, leaving `/mcp` answering HTTP 500).

  Anubis' own `:authorization` option is never passed. It configures an OAuth 2.1
  resource server: Peri **requires** `resource` and `authorization_servers`
  (supplying only a validator raised `%Peri.InvalidSchema{}` during `init/1`, so
  the server never started), and the plug then calls `validate_token/2` on the
  validator, which `ForemanServer.MCP.Auth` does not define. Foreman
  authenticates with its own bearer-token gate instead: the `ForemanServer.MCP.Auth`
  Plug in front of the HTTP transport and `call/4` for every tool call on both
  transports, each honouring `allow_insecure_local`. Both transports share this
  function.
  """
  @spec transport_opts(keyword(), :stdio | {:streamable_http, keyword()}) :: keyword()
  def transport_opts(opts, transport) do
    opts
    |> Keyword.delete(:authorization)
    |> Keyword.put_new(:transport, transport)
  end

  # Deliberately total over the documented `call_tool/2` contract and nothing
  # else. There is no permissive catch-all: an unexpected return raises a
  # FunctionClauseError instead of being reported to the client as a
  # successful result.
  defp wrap({:ok, data}, frame) do
    {:reply, Response.text(Response.tool(), Jason.encode!(data)), frame}
  end

  defp wrap({:error, %ToolError{code: code, message: message}}, frame) do
    {:error, error(code, message), frame}
  end

  @doc """
  Builds the JSON-RPC error for a typed tool failure.

  JSON-RPC 2.0 requires an integer `error.code`, so the wire code is an integer
  (`-32602` invalid params, `-32601` unknown tool, `-32001` unauthorized,
  `-32003` policy refused, `-32000` for every other domain failure) and the
  typed string (`"schedule_deleted"`, `"NOT_FOUND"`, ...) is carried in
  `error.data.code` for clients that branch on it.
  """
  @spec error(String.t(), String.t()) :: Error.t()
  def error(code, message) when is_binary(code) do
    %Error{code: wire_code(code), reason: :execution_error, message: message, data: %{code: code}}
  end

  defp wire_code("INVALID_PARAMS"), do: -32_602
  defp wire_code("missing_or_invalid"), do: -32_602
  defp wire_code("METHOD_NOT_FOUND"), do: -32_601
  defp wire_code("UNAUTHORIZED"), do: -32_001
  defp wire_code("POLICY_REFUSED"), do: -32_003
  defp wire_code(_domain), do: -32_000

  # Converts JSON arguments (string keys) into the atom keys the
  # `Tools.call_tool/2` clauses pattern-match. Only keys declared in the tool's
  # own `inputSchema` are converted, so no atom is ever created from caller
  # input; undeclared keys pass through untouched.
  defp input_validator(input_schema) do
    declared =
      input_schema
      |> Map.get(:properties, %{})
      |> Map.new(fn {key, _spec} -> {to_string(key), atomize(key)} end)

    fn args when is_map(args) ->
      {:ok, Map.new(args, fn {key, value} -> {translate(declared, key), value} end)}
    end
  end

  defp translate(declared, key) when is_binary(key), do: Map.get(declared, key, key)
  defp translate(_declared, key), do: key

  defp atomize(key) when is_atom(key), do: key
  defp atomize(key) when is_binary(key), do: String.to_atom(key)
end
