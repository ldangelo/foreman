defmodule ForemanServer.RunSlots.Config do
  @moduledoc """
  Accessors for RunSlots capacity configuration.

  Values are read at command-dispatch time, not inside aggregate decisions.
  """

  @doc """
  Returns the per-project concurrent runs cap used when a project sets no limit of its own.
  Defaults to 3 (PRD AC-002-1). There is no global cap: every project queues on its own stream.
  """
  def max_concurrent_runs_per_project do
    Application.get_env(:foreman_server, :max_concurrent_runs_per_project, 3)
  end
end
