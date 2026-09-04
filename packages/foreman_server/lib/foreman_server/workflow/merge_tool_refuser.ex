defmodule ForemanServer.Workflow.MergeToolRefuser do
  @moduledoc """
  Refuses direct merge tool calls from agents; logs security event.
  TRD-2026-4212be7e / MGH-T003 / TRD-073.
  """
  require Logger

  def refuse(actor, tool, reason) do
    Logger.error("MERGE REFUSED: actor=#{actor} tool=#{tool} reason=#{reason}")

    :telemetry.execute([:foreman_server, :security, :merge_refused], %{count: 1}, %{
      actor: actor,
      tool: tool,
      reason: reason
    })

    {:error, :merge_refused,
     "Direct merge tool calls by agents are not permitted; route through MergeGate."}
  end

  def permitted?(actor), do: actor == "merge_gate" or actor == "human:operator"
end
