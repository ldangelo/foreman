defmodule ForemanServer.AgentRuntime.JidoHarness.DetachedRun do
  @moduledoc """
  Foreman-side wrapper around `Jido.Harness.Run` for detached (one-shot) runs.

  TRD-2026-8a1f3c2e / TRD-010 — explicit `start_run/3`, `await_run/2`,
  `cancel_run/1` façade used by `InvocationSupervisor` to wire the
  detached run lifecycle.

  The vendored upstream exposes

      Jido.Harness.Run.start(provider, request, options) :: result(String.t())
      Jido.Harness.Run.await(run_id, timeout) :: result(Jido.Harness.RunResult.t())
      Jido.Harness.Run.cancel(run_id) :: :ok | {:error, term()}

  This wrapper is a thin pass-through; no behavior is added.
  """

  alias Jido.Harness.Run

  @doc """
  Starts a detached run and returns the run id.
  """
  @spec start_run(Jido.Harness.provider(), Jido.Harness.request(), keyword()) ::
          Jido.Harness.result(String.t())
  def start_run(provider, request, options \\ []), do: Run.start(provider, request, options)

  @doc """
  Waits for a run to finish and returns the final `RunResult` without
  cancelling the run when the wait times out.
  """
  @spec await_run(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.RunResult.t())
  def await_run(run_id, timeout \\ :infinity), do: Run.await(run_id, timeout)

  @doc """
  Requests cancellation of a running provider execution.
  """
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id), do: Run.cancel(run_id)
end
