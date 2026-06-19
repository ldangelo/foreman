defmodule ForemanServer do
  @moduledoc """
  OTP application shell for Foreman's Elixir orchestration server.

  The public API is intentionally small at this stage. Later TRD tasks add the
  HTTP boundary, Postgres event store, projections, and worker protocol behind
  this application/supervision topology.
  """

  alias ForemanServer.{CommandRouter, ProjectRegistry, RunActor, Scheduler}

  @doc "Returns currently supervised project IDs."
  @spec active_projects() :: [String.t()]
  def active_projects do
    ProjectRegistry.active_project_ids()
  end

  @doc "Routes a validated command into the server event boundary."
  @spec handle_command(map()) :: {:ok, map()} | {:error, term()}
  def handle_command(command) when is_map(command) do
    CommandRouter.handle(command)
  end

  def handle_command(_command), do: {:error, :invalid_command}

  @doc "Starts a supervised workflow run actor."
  @spec start_run(map()) :: {:ok, pid()} | {:error, term()}
  def start_run(spec) when is_map(spec), do: RunActor.start_run(spec)

  @doc "Returns current run actor state if it is alive."
  @spec run_state(String.t()) :: map() | nil
  def run_state(run_id) when is_binary(run_id), do: RunActor.state(run_id)

  @doc "Runs one scheduler dispatch tick."
  @spec scheduler_tick(keyword()) :: {:ok, map()} | {:error, term()}
  def scheduler_tick(opts \\ []), do: Scheduler.tick(opts)
end
