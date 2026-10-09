defmodule ForemanServer.Jobsite.Runner do
  @moduledoc """
  Behaviour for "run one agent iteration against a sandbox", abstracting the
  one genuine difference between a Jobsite script and a lowered Foreman
  workflow phase: how the agent is spawned.

  `ForemanServer.Jobsite.Runners.Direct` calls `Jido.Harness.Run` directly
  and supports a live multi-iteration loop (`iterations: :many`).
  `ForemanServer.Jobsite.Runners.Overwatch` dispatches through
  `ForemanServer.Overwatch.start_phase/2` so the spawned worker is tracked
  by `StuckDetector`/`StallDetector` and its stdout/stderr are durably
  logged — mandatory for a manifest-driven run, at the cost of one
  invocation per call (`iterations: :one`, `live_stream: false`).
  """

  alias ForemanServer.Jobsite.{Agent, Error, IterationResult, Sandbox}

  @callback capabilities() :: %{iterations: :one | :many, live_stream: boolean()}
  @callback run(
              agent :: Agent.t(),
              prompt :: String.t(),
              sandbox :: Sandbox.t(),
              opts :: keyword()
            ) ::
              {:ok, IterationResult.t()} | {:error, Error.t()}
end
