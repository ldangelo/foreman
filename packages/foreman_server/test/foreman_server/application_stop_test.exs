defmodule ForemanServer.ApplicationStopTest do
  @moduledoc """
  foreman-zmhzw. A graceful shutdown (SIGTERM) stops the supervision tree, then the harness - which
  kills each agent's own process group as it stops. The tool processes an agent started run in
  sessions of their own, so they survived the shutdown, re-parented to pid 1, in worktrees nobody
  owned any more.

  A REAL harness run (pi adapter, `fake_agent.sh` under erlexec) with a real tool process. The test
  calls the application's own `prep_stop/1` callback, which kills every live agent in this VM: hence
  `async: false`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.StrayAgent

  @moduletag :tmp_dir

  test "stopping the application takes out the live agent and the tool process it started",
       %{tmp_dir: dir} do
    %{agent_os_pid: agent, stray_pid: stray} = StrayAgent.start!(dir)
    assert StrayAgent.alive?(agent)
    assert StrayAgent.alive?(stray)

    assert [] = ForemanServer.Application.prep_stop([])

    refute StrayAgent.alive?(agent)
    refute StrayAgent.alive?(stray), "the tool process outlived the shutdown"
  end

  test "with no agent running it stops at once" do
    assert [] = ForemanServer.Application.prep_stop([])
  end
end
