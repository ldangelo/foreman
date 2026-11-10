defmodule ForemanServer.Events.RunRecoveryAttempted do
  @moduledoc """
  Typed event for a recovery step on a run that exists and is not terminal
  (`run.recovery_attempt`), folded into the run projection's `run.recovery`.

    * `outcome` - `resumed` (a restarted executor resumed the run, written by
      `RunExecutor` for every resume), or `effect_retried` / `effect_blocked`
      (the verdict of an external-effect reconciler, written by the effect
      recovery step only).
    * `elapsed_since_boot_ms` - monotonic time from application start to this
      record (`System.monotonic_time(:millisecond) - Incarnation.started_at_ms()`).
    * `reason` - optional free-text detail.
    * `effect_class`, `effect_key`, `effect_verdict` - the effect recovery
      reached a verdict for; present only on the two effect outcomes.

  The creation of this module is its registration: `EventCodec` derives its
  registry from `events/**/*.ex`.
  """
  @enforce_keys [:run_id, :outcome, :elapsed_since_boot_ms]
  @type t :: %__MODULE__{
          run_id: String.t(),
          outcome: String.t(),
          elapsed_since_boot_ms: non_neg_integer(),
          reason: String.t() | nil,
          effect_class: String.t() | nil,
          effect_key: String.t() | nil,
          effect_verdict: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :outcome,
    :elapsed_since_boot_ms,
    :reason,
    :effect_class,
    :effect_key,
    :effect_verdict,
    :sequence
  ]
end
