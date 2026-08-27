defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerEnvTest do
  @moduledoc """
  Pins the only hop that delivers Foreman's worker env to a dispatched
  agent: `Overwatch.start_phase/2` forwards its computed env map to the
  adapter as `:env_map`, and this worker must fold it into the driver opts
  as `:env` so `Jido.Harness` overlays it onto the agent process.

  Without this, every `FOREMAN_*` export (`FOREMAN_ARTIFACT_PATH`,
  `BEADS_DB`, `TRD_SCOPE`, the planning document paths) is computed,
  attached to the launch, and then silently dropped — the agent runs with
  none of them set, which is how run-d6cdefe69706087e6bce5b1a10b95384
  reported `FOREMAN_PRD_PATH: unset/empty` while quoting the contract that
  names it.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker

  defp init_opts(extra) do
    [
      worker_id: "wkr-env-test",
      run_id: "run-env-test",
      provider: :pi,
      prompt: "/skill:ensemble-full-create-prd --foreman",
      driver_opts: [cwd: "/tmp", await_timeout: 1_000]
    ] ++ extra
  end

  test "env_map is forwarded to the driver as :env, preserving existing driver opts" do
    env = %{"FOREMAN_TASK_TITLE" => "Implement durable run-log store", "BEADS_DB" => "/db"}

    assert {:ok, state} = JidoHarnessWorker.init(init_opts(env_map: env))

    assert Keyword.get(state.driver_opts, :env) == env
    assert Keyword.get(state.driver_opts, :cwd) == "/tmp"
    assert Keyword.get(state.driver_opts, :await_timeout) == 1_000
  end

  test "an absent or empty env_map injects nothing" do
    assert {:ok, without} = JidoHarnessWorker.init(init_opts([]))
    refute Keyword.has_key?(without.driver_opts, :env)

    assert {:ok, empty} = JidoHarnessWorker.init(init_opts(env_map: %{}))
    refute Keyword.has_key?(empty.driver_opts, :env)
  end

  test "a non-map env_map raises rather than launching with a dropped env" do
    assert_raise ArgumentError, fn ->
      JidoHarnessWorker.init(init_opts(env_map: [{"FOREMAN_TASK_TITLE", "x"}]))
    end
  end
end
