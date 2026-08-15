defmodule ForemanServer.RunSlots.Config do
  @moduledoc """
  Accessors for RunSlots capacity configuration.

  Values are read at command-dispatch time, not inside aggregate decisions.
  """

  @doc """
  Returns the global max concurrent runs cap.
  Defaults to 3.
  """
  def max_concurrent_runs do
    Application.get_env(:foreman_server, :max_concurrent_runs, 3)
  end

  @doc """
  Returns the per-project concurrent runs cap.
  Defaults to 100.
  """
  def max_concurrent_runs_per_project do
    Application.get_env(:foreman_server, :max_concurrent_runs_per_project, 100)
  end
end
