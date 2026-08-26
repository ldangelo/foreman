defmodule ForemanServer.Agents.LitellmUnavailableHandler do
  @moduledoc "Handles LiteLLM unavailable — blocks task. No direct API key fallback. TRD-2026-4212be7e / LGL-T005 / TRD-046."

  require Logger

  def handle(reason) do
    Logger.error("LiteLLM unavailable: #{inspect(reason)}; marking task blocked")
    {:blocked, %{reason: :litellm_unavailable, detail: reason}}
  end
end
