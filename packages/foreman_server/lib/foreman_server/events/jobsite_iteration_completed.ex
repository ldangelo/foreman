defmodule ForemanServer.Events.JobsiteIterationCompleted do
  @moduledoc """
  Typed event emitted when a jobsite iteration finishes.

  `text` is capped at 64 KiB (mirroring `Jido.Harness.RunResult.text_truncated?`)
  so the event stream stays replayable; `text_truncated?` is set when the cap
  bites. The full stream is written to the per-jobsite log file instead.
  """
  @enforce_keys [:jobsite_id, :index, :status]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          index: pos_integer(),
          status: String.t(),
          text: String.t() | nil,
          text_truncated?: boolean() | nil,
          session_id: String.t() | nil,
          usage: map() | nil,
          signalled?: boolean() | nil,
          matched_signal: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :jobsite_id,
    :index,
    :status,
    :text,
    :text_truncated?,
    :session_id,
    :usage,
    :signalled?,
    :matched_signal
  ]
end
