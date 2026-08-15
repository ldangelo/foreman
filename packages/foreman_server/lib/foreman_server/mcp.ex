defmodule ForemanServer.MCP do
  @moduledoc """
  Anubis MCP server wrapper.

  Wraps `AnubisMCPServer` with ForemanServer configuration and supervision.
  """

  @doc """
  Returns the child specification for the MCP server.
  """
  def child_spec(_init_arg) do
    %{
      id: __MODULE__,
      start: {Anubis.Server, :start_link, [[]]},
      type: :supervisor
    }
  end

  @doc """
  Returns the configured MCP child spec based on application environment.
  """
  def mcp_child_spec do
    case Application.get_env(:foreman_server, :mcp, [])[:enabled] do
      true ->
        [child_spec(nil)]

      _ ->
        []
    end
  end
end
