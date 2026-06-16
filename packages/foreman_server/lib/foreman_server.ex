defmodule ForemanServer do
  @moduledoc """
  OTP application shell for Foreman's Elixir orchestration server.

  The public API is intentionally small at this stage. Later TRD tasks add the
  HTTP boundary, Postgres event store, projections, and worker protocol behind
  this application/supervision topology.
  """

  alias ForemanServer.CommandRouter
  alias ForemanServer.ProjectRegistry

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
end
