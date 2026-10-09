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

  @optional_callbacks step_failed: 4
end
