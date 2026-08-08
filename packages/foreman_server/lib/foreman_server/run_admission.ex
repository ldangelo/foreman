defmodule ForemanServer.RunAdmission do
  @moduledoc """
  One-way internal run-admission surface.

      Dispatcher / Reconciler -> RunAdmission.start/2 -> CommandRouter.dispatch_run_start/2 -> CommandRouter.do_dispatch/2

  Supervised workflow components MUST enter through `start/2` so
  `[:foreman, :run_admission, :start]` telemetry is emitted consistently.
  """

  alias ForemanServer.{CommandRouter, Telemetry}

  @spec start(String.t(), map(), integer()) :: {:ok, map() | nil} | {:error, any()}
  def start(project_id, payload, timeout \\ 5_000)

  def start(project_id, payload, timeout)
      when is_binary(project_id) and project_id != "" and is_map(payload) do
    Telemetry.run_admission_start(
      project_id,
      Map.get(payload, :run_id),
      Map.get(payload, :task_id)
    )

    CommandRouter.dispatch_run_start(project_id, payload, timeout)
  end

  def start(project_id, _payload, _timeout),
    do: {:error, {:missing_or_invalid, :project_id, project_id}}
end
