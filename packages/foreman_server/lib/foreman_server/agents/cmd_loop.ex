defmodule ForemanServer.Agents.CmdLoop do
  @moduledoc """
  Foreman-side cmd/2 loop implementation that delegates to Jido.Agent.cmd/2.
  Returns updated agent struct + directives.
  TRD-2026-4212be7e / JCR-T003 / TRD-005.
  """
  alias Jido.Agent

  def call(agent, action_module, params \\ %{}) do
    Agent.cmd(agent, action_module, params)
  end

  def apply_and_dispatch(agent, action_module, params \\ %{}) do
    case Agent.cmd(agent, action_module, params) do
      {:ok, updated_agent, directives} ->
        Enum.each(directives, fn _directive -> :ok end)
        {:ok, updated_agent, length(directives)}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
