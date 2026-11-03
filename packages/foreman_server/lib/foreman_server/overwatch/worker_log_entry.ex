defmodule ForemanServer.Overwatch.WorkerLogEntry do
  @moduledoc """
  One stdout/stderr line of a harness run, on its way into the worker's event stream.

  `JidoHarnessWorker` is the only producer (the live tail and the finished run both build their
  entries through its one event-to-entry mapping) and the only consumer (it writes each entry as
  a `WorkerStdout` / `WorkerStderr`). The struct exists so that boundary is typed: an entry
  without a `sequence` cannot be built, instead of failing with a `KeyError` once the worker
  reads it.

  * `channel` - the durable channel the line belongs to.
  * `data` - the text of the harness event. Usually a binary. The live tail reads the run's
    journal, which stores text that is not valid UTF-8 as a
    `%{"encoding" => "base64", "data" => ...}` map, so the type is open and
    `WorkerLogPolicy.normalize/3` turns anything into a line.
  * `timestamp` - the harness event's own timestamp, carried onto the stored event.
  * `sequence` - the harness event's own sequence. A run numbers its events from 1
    (`Jido.Harness.Event.attach/4`; 0 is only the default of an event no run has seen), so it is
    a positive integer. It is the cursor a line is written by: an entry at or behind the last one
    written is skipped, so a line is written once whichever path delivers it first.
  """

  @enforce_keys [:channel, :data, :timestamp, :sequence]
  defstruct [:channel, :data, :timestamp, :sequence]

  @type channel :: :worker_stdout | :worker_stderr

  @type t :: %__MODULE__{
          channel: channel(),
          data: term(),
          timestamp: String.t(),
          sequence: pos_integer()
        }
end
