defmodule ForemanServer.Events.WorkerStarted do
  @moduledoc """
  Typed event emitted when a worker process has started.

  ## Launch context

  Beyond the liveness keys, `WorkerStarted` carries the launch context
  used by downstream tooling, recovery, and the run projection. Tests
  rely on `session_id`, `adapter`, `prompt_path`, `tool_names`, and
  `artifact_paths` being present in the appended event.

    * `session_id` — opaque session identifier tied to the worker
      runtime (e.g. CLI session UUID).
    * `adapter` — module name of the runtime adapter that owns this
      worker (e.g. `ForemanServer.Overwatch.Adapters.CliWorker`).
    * `prompt_path` — file path of the rendered prompt handed to the
      worker at launch time.
    * `tool_names` — list of tool names exposed to the worker runtime.
    * `artifact_paths` — list of artifact paths the worker should write
      to during its run.

  These fields MUST be supplied by the high-level launcher
  (`ForemanServer.Overwatch.start_phase/2`). Routing workers via
  `WorkerProtocol.emit(:worker_started, ...)` accepts them through the
  payload map.
  """

  @enforce_keys [:worker_id, :run_id, :session_id, :adapter, :prompt_path]

  @derive Jason.Encoder
  defstruct [
    :worker_id,
    :run_id,
    :session_id,
    :adapter,
    :prompt_path,
    :sequence,
    tool_names: [],
    artifact_paths: []
  ]

  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          session_id: String.t(),
          adapter: String.t(),
          prompt_path: String.t(),
          tool_names: [String.t()],
          artifact_paths: [String.t()],
          sequence: non_neg_integer() | nil
        }
end
