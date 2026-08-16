defmodule ForemanServer.CLI.Doctor do
  @moduledoc false

  alias ForemanServerWeb.MCP.Tools.Doctor, as: MCPDoctor

  @spec run(keyword()) :: :ok | {:error, :provider_missing}
  def run(opts \\ []) when is_list(opts) do
    case MCPDoctor.run(opts) do
      {:ok, output} ->
        IO.puts(output)
        :ok

      {:error, :provider_missing, output} ->
        IO.puts(output)
        {:error, :provider_missing}
    end
  end
end
