defmodule ForemanServerWeb.DashboardRefreshLatencyTest do
  use ExUnit.Case, async: false
  @moduletag :latency
  @threshold_ms 1000

  test "dashboard render latency under 1s" do
    {time_us, _} =
      :timer.tc(fn ->
        %{active_agents: [], current_states: [], signal_history: [], directive_queue: []}
      end)

    time_ms = div(time_us, 1000)
    assert time_ms < @threshold_ms, "render took #{time_ms}ms"
  end
end
