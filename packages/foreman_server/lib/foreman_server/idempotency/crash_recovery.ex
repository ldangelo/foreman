defmodule ForemanServer.Idempotency.CrashRecovery do
  @moduledoc """
  Crash recovery reconciliation: completed -> skip; ambiguous -> check side effects before retry.
  TRD-2026-4212be7e / RTE-T003 / TRD-077.
  """
  require Logger

  def reconcile(key, side_effects_check \\ &has_no_side_effects?/1) do
    case ForemanServer.Idempotency.KeyStore.status(key) do
      {:ok, :completed} ->
        Logger.info("Recovery: key=#{key} completed; skipping")
        {:skip, :already_completed}
      {:ok, :ambiguous} ->
        Logger.warning("Recovery: key=#{key} ambiguous; checking side effects")
        if side_effects_check.(key), do: {:retry, :no_side_effects}, else: {:retry, :side_effects_present}
      :not_found ->
        {:retry, :fresh}
      _ ->
        {:retry, :unknown_state}
    end
  end

  defp has_no_side_effects?(_key), do: true
end
