defmodule ForemanServer.Jobsite.Observer do
  @moduledoc """
  Callbacks `ForemanServer.Jobsite.Engine.run_program/3` invokes around each
  step (and, for an `:agent` step, around each iteration within it). An
  observer owns every side effect that isn't "run the step" — event
  dispatch, phase-completion commands, artifact capture — so the engine
  itself stays free of both Jobsite's and Foreman's vocabulary.

  Two observers exist: `ForemanServer.Jobsite.Executor.Observer` (dispatches
  `jobsite.*` commands, step 14/19) and `ForemanServer.Workflow.JobsiteObserver`
  (dispatches `phase.*` commands, step 22).

  `step_started/3` may return a third element, a map of opts merged into
  that one step (for an `:agent` step, into that iteration's step): the way
  an observer supplies what only run state can compute — a worktree it
  provisioned, an agent launch spec — without the program knowing it up
  front.

  `step_completed/4` returns a `Context.t()` (not just `:ok`) so an observer
  can enrich it — the Foreman observer uses that to set `artifact_path` and
  to record a captured planning document path. Returning `{:error, _}` from
  either callback halts the program; the engine never retries a step.

  `step_failed/4` is optional and runs for every failure, whether the step's
  own or an observer rejection from `step_completed/4`. It can keep the
  failure (`{:ok, state}`), replace the error, or report that the failure
  is really an interruption (`{:interrupted, kind, reason, state}`).

  `session_bound/4` is optional and is told, while an `:agent` step's iteration
  is still running, the provider session id its run was given (the `step` is
  that iteration's, with `iteration_index`). It is how an observer records the
  session durably BEFORE the iteration finishes, so a crash mid-iteration still
  leaves a session to resume. It is a notification: its return value does not
  stop the program, and an observer that cannot record the id reports that
  itself.
  """

  alias ForemanServer.Jobsite.{Context, Error, Step}

  @callback step_started(Step.t(), Context.t(), state :: term()) ::
              {:ok, term()} | {:ok, term(), overrides :: map()} | {:error, Error.t()}
  @callback step_completed(Step.t(), Context.t(), result :: term(), state :: term()) ::
              {:ok, Context.t(), term()} | {:error, Error.t()}
  @callback step_failed(Step.t(), Error.t(), Context.t(), state :: term()) ::
              {:ok, term()}
              | {:error, Error.t(), term()}
              | {:interrupted, atom(), String.t(), term()}
  @callback session_bound(Step.t(), Context.t(), session_id :: String.t(), state :: term()) ::
              :ok | {:error, Error.t()}

  @optional_callbacks step_failed: 4, session_bound: 4
end
