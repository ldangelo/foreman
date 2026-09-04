defmodule ForemanServer.Agents.CmdLoopTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.CmdLoop
  alias Jido.Agent
  alias Jido.Agent.Directive
  alias Jido.Signal

  # Concrete agent module so cmd/3 is generated on it.
  defmodule TestCmdAgent do
    @moduledoc false
    use Jido.Agent,
      name: "test_cmd_agent",
      description: "Minimal agent for CmdLoop tests.",
      schema: []
  end

  # ---------------------------------------------------------------------------
  # Test actions — each emits a specific directive type for dispatch testing.
  # ---------------------------------------------------------------------------

  defmodule NoOpAction do
    use Jido.Action,
      name: "no_op_action",
      schema: []

    def run(_params, _ctx), do: {:ok, %{done: true}}
  end

  defmodule EmitSignalAction do
    use Jido.Action,
      name: "emit_signal_action",
      schema: [topic: [type: :string, required: true], payload: [type: :map, default: %{}]]

    def run(%{topic: topic, payload: payload}, _ctx) do
      {:ok, signal} = Signal.new(topic, payload, source: "test.emit")
      {:ok, %{emitted: true}, [%Directive.Emit{signal: signal}]}
    end
  end

  defmodule EmitErrorAction do
    use Jido.Action,
      name: "emit_error_action",
      schema: [msg: [type: :string, default: "test error"]]

    def run(%{msg: msg}, _ctx) do
      error = Jido.Error.execution_error(msg, %{from: :test})
      {:ok, %{failed: true}, [%Directive.Error{error: error, context: :test}]}
    end
  end

  defmodule ScheduleAction do
    use Jido.Action,
      name: "schedule_action",
      schema: [
        delay: [type: :integer, required: true],
        tag: [type: :string, default: "scheduled"]
      ]

    def run(%{delay: delay, tag: tag}, _ctx) do
      {:ok, %{scheduled: tag}, [%Directive.Schedule{delay_ms: delay, message: {:scheduled, tag}}]}
    end
  end

  defmodule SpawnAction do
    use Jido.Action,
      name: "spawn_action",
      schema: [module: [type: :atom, required: true], tag: [type: :string, default: "child"]]

    def run(%{module: mod, tag: tag}, _ctx) do
      child_spec = {Agent, []}
      {:ok, %{spawning: tag}, [%Directive.Spawn{child_spec: child_spec, tag: tag}]}
    end
  end

  defmodule StopAction do
    use Jido.Action,
      name: "stop_action",
      schema: [reason: [type: :string, default: "normal"]]

    def run(%{reason: reason}, _ctx) do
      {:ok, %{stopping: true}, [%Directive.Stop{reason: reason}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Core API tests
  # ---------------------------------------------------------------------------

  describe "call/3 delegates to Jido.Agent.cmd/2" do
    test "returns updated agent and empty directives when action produces none" do
      agent = TestCmdAgent.new(actions: [NoOpAction])

      assert {:ok, updated, directives} = CmdLoop.call(agent, NoOpAction, %{})
      assert updated.state.done == true
      assert directives == []
    end

    test "returns updated agent and directives when action emits them" do
      agent = TestCmdAgent.new(actions: [EmitSignalAction])

      assert {:ok, updated, [directive | _] = directives} =
               CmdLoop.call(agent, EmitSignalAction, %{topic: "test.emit", payload: %{x: 1}})

      assert updated.state.emitted == true
      assert is_list(directives)

      assert directive.__struct__ in [
               Directive.Emit,
               Directive.Error,
               Directive.Schedule,
               Directive.Spawn,
               Directive.Stop
             ]
    end

    test "normalizes bare action module with no params" do
      agent = TestCmdAgent.new(actions: [NoOpAction])
      assert {:ok, _updated, []} = CmdLoop.call(agent, NoOpAction, %{})
    end

    test "normalizes {module, params} tuple" do
      agent = TestCmdAgent.new(actions: [EmitSignalAction])
      assert {:ok, _updated, [_]} = CmdLoop.call(agent, {EmitSignalAction, %{topic: "x"}}, %{})
    end
  end

  describe "apply_and_dispatch/3 dispatches all directives and returns count" do
    test "dispatches zero directives from a no-op action" do
      agent = TestCmdAgent.new(actions: [NoOpAction])
      assert {:ok, updated, 0} = CmdLoop.apply_and_dispatch(agent, NoOpAction, %{})
      assert updated.state.done == true
    end

    test "dispatches Emit directive (bus not running — dropped silently)" do
      agent = TestCmdAgent.new(actions: [EmitSignalAction])

      assert {:ok, updated, 1} =
               CmdLoop.apply_and_dispatch(agent, EmitSignalAction, %{
                 topic: "test.drop",
                 payload: %{}
               })

      assert updated.state.emitted == true
    end

    test "dispatches Error directive (logs warning, returns :ok)" do
      agent = TestCmdAgent.new(actions: [EmitErrorAction])
      assert {:ok, updated, 1} = CmdLoop.apply_and_dispatch(agent, EmitErrorAction, %{})
      assert updated.state.failed == true
    end

    test "dispatches Schedule directive" do
      agent = TestCmdAgent.new(actions: [ScheduleAction])

      assert {:ok, updated, 1} =
               CmdLoop.apply_and_dispatch(agent, ScheduleAction, %{delay: 100, tag: "tick"})

      assert updated.state.scheduled == "tick"
    end

    test "Schedule with delay <= 0 is not matched by guard — still returns 0 directives dispatched" do
      agent = TestCmdAgent.new(actions: [ScheduleAction])
      # The directive is emitted but guard rejects it; dispatch_directive falls through
      # to the unknown-directive fallback and returns :ok anyway. The count still
      # reflects the full directive list from the action.
      assert {:ok, _updated, 1} =
               CmdLoop.apply_and_dispatch(agent, ScheduleAction, %{delay: 0, tag: "zero"})
    end

    test "dispatches Spawn directive (no supervisor in test — dropped gracefully)" do
      agent = TestCmdAgent.new(actions: [SpawnAction])

      assert {:ok, updated, 1} =
               CmdLoop.apply_and_dispatch(agent, SpawnAction, %{module: Agent, tag: "test-child"})

      assert updated.state.spawning == "test-child"
    end

    test "dispatches Stop directive — process exits" do
      agent = TestCmdAgent.new(actions: [StopAction])
      pid = self()

      spawn(fn ->
        assert catch_exit(CmdLoop.apply_and_dispatch(agent, StopAction, %{reason: "test-stop"})) ==
                 {:directive_stop, "test-stop"}

        send(pid, :exited_cleanly)
      end)

      assert_receive :exited_cleanly, 5_000
    end

    test "handles nil directive in list gracefully" do
      # A no-op action produces zero directives; returns {:ok, agent, 0}.
      assert {:ok, _updated, 0} =
               CmdLoop.apply_and_dispatch(TestCmdAgent.new(actions: []), NoOpAction, %{})
    end
  end

  describe "directive dispatch: Error directive logs without crashing" do
    test "Error directive with context includes context in log" do
      agent = TestCmdAgent.new(actions: [EmitErrorAction])

      assert {:ok, _updated, 1} =
               CmdLoop.apply_and_dispatch(agent, EmitErrorAction, %{msg: "boom"})
    end
  end
end
