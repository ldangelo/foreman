defmodule ForemanServer.FollowUpRuns do
  @moduledoc """
  The gate of the follow-up run kind (`run.followup.request`, docs/plans/retire-jobsites.md).

  `config :foreman_server, :followup_runs, enabled: false` (the default) refuses the command, so no
  `RunFollowUpRequested` event is written and a build without that event can still be rolled back
  to. Tests state the gate they need with `enable!/0` / `disable!/0`.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    :foreman_server |> Application.get_env(:followup_runs, []) |> Keyword.get(:enabled, false)
  end

  @spec enable!() :: :ok
  def enable!, do: put(true)

  @spec disable!() :: :ok
  def disable!, do: put(false)

  defp put(value) do
    Application.put_env(:foreman_server, :followup_runs, enabled: value)
  end
end
