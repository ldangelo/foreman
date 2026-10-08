defmodule ForemanServer.Jobsite.ExecResult do
  @moduledoc "Result of a single `Jobsite.Sandbox.exec/3` command. A non-zero `exit_code` is data, not a failure."
  @enforce_keys [:stdout, :stderr, :exit_code]
  @type t :: %__MODULE__{stdout: String.t(), stderr: String.t(), exit_code: integer()}
  defstruct [:stdout, :stderr, :exit_code]
end

defmodule ForemanServer.Jobsite.IterationResult do
  @moduledoc """
  Result of a single agent iteration.

  `status` is `:completed | :failed | :cancelled | :signalled | :hanging` —
  the last two are Jobsite-level outcomes, never returned by jido_harness
  itself.
  """
  @enforce_keys [:index, :status, :text]
  @type status :: :completed | :failed | :cancelled | :signalled | :hanging
  @type t :: %__MODULE__{
          index: pos_integer(),
          status: status(),
          text: String.t(),
          text_truncated?: boolean(),
          session_id: String.t() | nil,
          usage: map(),
          signalled?: boolean(),
          matched_signal: String.t() | nil
        }
  defstruct [
    :index,
    :status,
    :text,
    text_truncated?: false,
    session_id: nil,
    usage: %{},
    signalled?: false,
    matched_signal: nil
  ]
end

defmodule ForemanServer.Jobsite.Result do
  @moduledoc "Final result of a completed (or paused) jobsite run, returned by `Jobsite.run/1` and `Jobsite.resume/1`."
  @enforce_keys [:jobsite_id, :iterations, :branch, :commits]
  @type commit :: %{sha: String.t(), subject: String.t()}
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          iterations: [ForemanServer.Jobsite.IterationResult.t()],
          branch: String.t() | nil,
          commits: [commit()],
          status: atom() | nil,
          text: String.t(),
          output: term() | nil,
          log_path: String.t() | nil,
          session_id: String.t() | nil,
          worktree_path: String.t() | nil,
          merged?: boolean(),
          preserved_path: String.t() | nil
        }
  defstruct [
    :jobsite_id,
    :iterations,
    :branch,
    :commits,
    status: nil,
    text: "",
    output: nil,
    log_path: nil,
    session_id: nil,
    worktree_path: nil,
    merged?: false,
    preserved_path: nil
  ]
end
