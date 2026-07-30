defmodule ForemanServer.Overwatch.LaunchWorker do
  @moduledoc """
  Thin spawn helper for worker processes.  `start_link/1` launches a linked worker
  child and registers it with the Tracker.  The supervisor treats this module as a
  child spec so restart policies apply to the whole spawn+track operation.
  """

  @doc """
  Starts a linked worker and registers it with the Tracker.

  Returns `{:ok, pid}` on success, `{:error, reason}` on spawn failure.
  """
  @spec start_link(String.t(), String.t(), String.t(), module(), map()) ::
          {:ok, pid()} | {:error, term()}
  def start_link(run_id, worker_id, phase_id, worker_module, env_opts \\ %{}) do
    case worker_module.start_link(env_opts) do
      {:ok, pid} ->
        :ok =
          ForemanServer.Overwatch.track_worker(
            pid,
            run_id,
            worker_id,
            phase_id,
            worker_module
          )

        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  @doc "Standard child_spec for supervisor tree inclusion."
  @spec child_spec({String.t(), String.t(), String.t(), module(), map()}) ::
          Supervisor.child_spec()
  def child_spec({run_id, worker_id, phase_id, worker_module, env_opts}) do
    %{
      id: {__MODULE__, run_id, worker_id},
      start: {__MODULE__, :start_link, [run_id, worker_id, phase_id, worker_module, env_opts]},
      restart: :permanent
    }
  end
end
