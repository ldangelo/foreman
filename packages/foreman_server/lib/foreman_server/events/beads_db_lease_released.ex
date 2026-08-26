defmodule ForemanServer.Events.BeadsDbLeaseReleased do
  @moduledoc """
  Typed event emitted when a holder releases the per-DB Beads lease.

  `reason` is one of `:run_completed`, `:run_failed`, `:run_cancelled`,
  `:run_flagged_stuck`, `:orphan_recovered` (boot reconciliation cleared
  a dead holder), or `:run_start_failed` (compensation after acquire
  succeeded but `run.start` rejected).
  """
  @enforce_keys [:db_path, :run_id, :released_at_ms, :reason]
  @type t :: %__MODULE__{
          db_path: String.t(),
          run_id: String.t(),
          released_at_ms: integer(),
          reason: atom()
        }
  @derive Jason.Encoder
  defstruct [:db_path, :run_id, :released_at_ms, :reason]
end
