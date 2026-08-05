defmodule ForemanServer.Events.WorkerCrashed do
  @moduledoc """
  Typed event emitted when the overwatch crash-loop detector marks a
  worker as unrecoverable.

  A `WorkerCrashed` event is appended to the `worker:<run_id>:<worker_id>`
  stream AND folds the Worker aggregate state into `status: "crashed"`
  with `terminal?: true` (joined to the existing `@terminal_events` set).

  ## Trigger semantics

  `WorkerCrashed` is emitted **only** by the crash-loop detector when the
  restart count exceeds the configured threshold (default 3) within the
  configured window (default 5 minutes). Orphan exits (`:noconnection`,
  parent-node death) do NOT emit `WorkerCrashed` — they are tracked in
  the detector's state for audit but rely on Tracker's slot cleanup
  alone. The AC for orphan handling is "worker is cleaned up and slot
  is released," not "worker is marked crashed."

  ## Field contract

    * `worker_id` — Worker aggregate stream id component (enforced).
    * `run_id` — Run aggregate stream id component (enforced).
    * `sequence` — Optional: sequence mirror. Optional to keep the
      detector independent of Tracker's sequence allocator.
    * `restarts_in_window` — Count of restarts observed within the
      configured crash window (e.g. 4 when threshold=3).
    * `window_ms` — Window length used by the detector (e.g. 300_000).
    * `reason` — Currently always `"crash_loop"`. Reserved for future
      values; orphan path does NOT use this event.

  Producers MUST emit the same fields declared here. Adding a new field
  requires updating both this struct and `ForemanServer.EventCodec`'s
  `@enforce_keys_registry`.
  """
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          restarts_in_window: non_neg_integer() | nil,
          window_ms: non_neg_integer() | nil,
          reason: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :restarts_in_window, :window_ms, :reason]
end
