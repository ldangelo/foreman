defmodule ForemanServer.AgentRuntime.JidoSupervisorTest do
  @moduledoc """
  Tests for `ForemanServer.AgentRuntime.JidoSupervisor` — the Foreman-side
  DynamicSupervisor that hosts `Jido.AgentServer` GenServer instances for
  Foreman workflow runs (TRD-2026-4212be7e, JCR-T002).

  Per JCR-T002 the Jido.Agent GenServer lives under the existing
  `ForemanServer.AgentRuntime.Supervisor` (which is itself conditional on
  `config :foreman_server, :agent_runtime, enabled: true`). The
  JidoSupervisor is a DynamicSupervisor so individual agents can be spawned
  and torn down per run without restarting the whole agent runtime.
  """

  use ExUnit.Case, async: false

  # Jido.AgentServer requires the :jido OTP application to be running
  # (it registers with Jido.Registry on init). The :foreman_server app
  # does not depend on :jido at the application level (Jido is opt-in
  # per the JCR-T002 supervision gating), so each test that exercises
  # Jido.AgentServer must start it locally.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido)
    :ok
  end

  alias ForemanServer.AgentRuntime.JidoSupervisor
  alias ForemanServer.TestSupport.InvocationSupervisorHelpers


  # Minimal stub Jido agent module used by start_agent/1 tests. Jido's
  # AgentServer.start_link/1 expects an `agent:` module that defines
  # `Jido.Agent` behaviour. We provide just enough to compile and start.
  defmodule StubAgent do
    @moduledoc "Stub Jido agent used by JidoSupervisor.start_agent/1 tests."

    use Jido.Agent,
      name: "stub_agent",
      description: "stub",
      schema: []

    def cmd(_agent, _action), do: {nil, []}
  end

  describe "start_link/1" do
    test "starts as a DynamicSupervisor under a unique name" do
      unique = :erlang.unique_integer()
      sup_name = :"JidoSupervisor.Test.#{unique}"

      InvocationSupervisorHelpers.schedule_preserve()

      pid =
        start_supervised!(
          {JidoSupervisor, [name: sup_name]},
          id: :Jido_supervisor_basic
        )

      assert is_pid(pid)
      assert Process.whereis(sup_name) == pid
    end

    test "can be embedded as a child of AgentRuntime.Supervisor" do
      unique = :erlang.unique_integer()
      jido_sup_name = :"JidoSupervisor.Test.#{unique}"

      InvocationSupervisorHelpers.schedule_preserve()

      # The whole AgentRuntime.Supervisor should be able to bring up the
      # JidoSupervisor as a child without error.
      sup_pid =
        start_supervised!(
          {ForemanServer.AgentRuntime.Supervisor,
           [
             jido_supervisor_name: jido_sup_name
           ]},
          id: :Jido_supervisor_under_ARS
        )

      assert is_pid(sup_pid)
      assert Process.whereis(jido_sup_name) != nil
    end
  end

  describe "start_agent/1" do
    test "starts a Jido.AgentServer under a uniquely-named supervisor" do
      unique = :erlang.unique_integer()
      sup_name = :"JidoSupervisor.Test.Agent.#{unique}"

      InvocationSupervisorHelpers.schedule_preserve()

      sup_pid =
        start_supervised!(
          {JidoSupervisor, [name: sup_name]},
          id: :Jido_supervisor_for_start_agent
        )

      # When started under a unique name, start_agent/1 must look up that
      # exact supervisor pid, not the default one. We pass the supervisor
      # pid explicitly via :supervisor so the implementation doesn't have
      # to hard-code __MODULE__.
      #
      # We also pass `register_global: false` so Jido.AgentServer doesn't
      # try to register with the user-provided `Jido.Registry` (which is
      # not started in this test scope). Per-run registry wiring belongs
      # to JCR-T004 (jido_ecto integration) — this test only verifies
      # the supervisor plumbing.
      result =
        JidoSupervisor.start_agent(
          supervisor: sup_pid,
          run_id: "test-run-#{unique}",
          agent: StubAgent,
          register_global: false
        )

      assert {:ok, _pid} = result
      assert Process.alive?(elem(result, 1))
    end
  end

  describe "child_spec/1" do
    test "returns a DynamicSupervisor-compatible child spec" do
      spec = JidoSupervisor.child_spec(name: :"JidoSupervisor.SpecTest")
      assert spec.id == JidoSupervisor
      assert spec.start == {JidoSupervisor, :start_link, [[name: :"JidoSupervisor.SpecTest"]]}
      assert spec.type == :supervisor
    end
  end
end
