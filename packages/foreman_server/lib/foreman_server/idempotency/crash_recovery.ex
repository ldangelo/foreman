defmodule ForemanServer.Idempotency.CrashRecovery do
  @moduledoc """
  Crash recovery reconciliation: completed -> skip; ambiguous -> check side effects before retry.

  When an ambiguous key has side effects, `reconcile/1,2` returns
  `{:retry, :side_effects_present}` and marks the key `completed` before
  returning so callers can safely retry without re-triggering ambiguity.

  Side effects checked:
    - PR created (`ProjectionStore.pr_association/1`)
    - Worktrees created (`ProjectionStore.worktrees_for_run/1` with status `"created"`)

  `run_id` is read from the KeyStore record metadata stored at
  `mark_started/2` time (via `HeartbeatLease.acquire/4`).  If no record
  exists or `run_id` is absent, falls back to `true` (assume no side effects)
  so recovery can still proceed.

  TRD-2026-4212be7e / RTE-T003 / TRD-077.
  Extends TRD-014 reconciliation rules (REQ-017, REQ-026).
  """
  require Logger

  alias ForemanServer.ProjectionStore

  # --- public API ---

  @doc """
  Reconcile an idempotency key after a crash.

  Returns:
    - `{:skip, :already_completed}` — key is completed; skip (no retry)
    - `{:retry, :no_side_effects}` — ambiguous/fresh; no side effects; safe to retry
    - `{:retry, :side_effects_present}` — ambiguous; side effects detected; mark completed, allow retry
    - `{:retry, :fresh}` — key not found; treat as new
    - `{:retry, :unknown_state}` — unexpected status; allow retry
  """
  @spec reconcile(key :: String.t(), side_effects_check :: (String.t() -> boolean())) ::
          {:skip, :already_completed}
          | {:retry, :no_side_effects | :side_effects_present | :fresh | :unknown_state}
  def reconcile(key, side_effects_check \\ &has_no_side_effects?/1)

  def reconcile(key, side_effects_check)
      when is_binary(key) and is_function(side_effects_check, 1) do
    case ForemanServer.Idempotency.KeyStore.status(key) do
      {:ok, :completed} ->
        Logger.info("CrashRecovery: key=#{key} completed; skipping")
        {:skip, :already_completed}

      {:ok, :ambiguous} ->
        Logger.warning("CrashRecovery: key=#{key} ambiguous; checking side effects")
        has_side_effects = not side_effects_check.(key)

        if has_side_effects do
          Logger.warning(
            "CrashRecovery: key=#{key} has side effects; marking completed before retry"
          )

          :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key, %{recovered: true})
          {:retry, :side_effects_present}
        else
          {:retry, :no_side_effects}
        end

      :not_found ->
        {:retry, :fresh}

      _other ->
        {:retry, :unknown_state}
    end
  end

  def reconcile(_key, _side_effects_check), do: {:retry, :unknown_state}

  # --- side effects detection ---

  @doc """
  Returns `true` when no irreversible side effects are detected for the
  given idempotency key. Used as the default `side_effects_check` in
  `reconcile/1,2`.

  `run_id` is read from the KeyStore record metadata stored at
  `mark_started/2` time (via `HeartbeatLease.acquire/4`).  If no record
  exists or `run_id` is absent, returns `true` (assume no side effects)
  so recovery can still proceed.
  """
  @spec has_no_side_effects?(key :: String.t()) :: boolean()
  def has_no_side_effects?(key) when is_binary(key) do
    case ForemanServer.Idempotency.KeyStore.get(key) do
      {:ok, %{metadata: %{run_id: run_id}}} when is_binary(run_id) and run_id != "" ->
        not (pr_created?(run_id) or worktrees_created?(run_id))

      _ ->
        # No record or no run_id stored — fall back to safe: allow retry.
        true
    end
  end

  def has_no_side_effects?(_), do: true

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp pr_created?(run_id) do
    case ProjectionStore.pr_association(run_id) do
      {:ok, %{pr_url: url}} when is_binary(url) and url != "" -> true
      _ -> false
    end
  end

  defp worktrees_created?(run_id) do
    run_id
    |> ProjectionStore.worktrees_for_run()
    |> Enum.any?(fn wt ->
      status = wt[:status] || wt["status"]
      status == "created"
    end)
  end
end
