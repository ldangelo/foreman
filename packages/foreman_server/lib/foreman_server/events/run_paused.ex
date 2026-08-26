defmodule ForemanServer.Events.RunPaused do
  @moduledoc """
  Typed event emitted when a run is paused.

  Pause is **recoverable** — `terminal?: false` on the Run aggregate so a
  subsequent `run.resume` (or any non-terminal mutating command) is
  accepted. Pause is distinct from cancellation or failure: it carries a
  human-meaningful reason (e.g. `"crash_loop"`, `"operator_intervention"`)
  and is intended to be visible to operators before resuming.

  ## Field contract

    * `run_id` — Run aggregate stream id component (enforced).
    * `sequence` — Optional sequence mirror (the Run aggregate does not
      require sequence; `validate_next_sequence` accepts `nil`).
    * `reason` — String reason for the pause. Informational only.
    * `metadata` — Map of arbitrary additional context. Default `%{}`.

  Producers MUST emit the same fields declared here.
  """
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          reason: String.t() | nil,
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :sequence, :reason, metadata: %{}]
end
