defmodule ForemanServer.Agents.JidoAgentLifecycleTest do
  @moduledoc """
  Unit tests for the Jido.Agent lifecycle: start (new/1), cmd/2 (action
  application), checkpoint (state serialization), and restart (restore/2).

  TRD-2026-4212be7e / JCR-T006 / TRD-008.

  The Jido.Agent module is a `use`-macro that generates an immutable
  agent struct with `new/1`, `cmd/2`, `checkpoint/2`, and `restore/2`
  callbacks. The GenServer wrapper is `Jido.AgentServer` (separate
  module, separate test). Persistence to Postgres is exercised end-to-end
  in JCR-T007 and is out of scope here — these tests verify the
  lifecycle contract against in-memory agent structs only.

  These tests do NOT need a Postgres connection, an EventStore, or any
  Application supervision tree beyond `Jido.Signal` (which AgentServer
  pulls in transitively).
  """

  use ExUnit.Case, async: false

  alias Jido.Agent
  alias Jido.AgentServer

  # ---------------------------------------------------------------------------
  # Test action: pure state mutation; no directives, no I/O.
  # ---------------------------------------------------------------------------

  defmodule StampAction do
    @moduledoc false
    use Jido.Action,
      name: "lifecycle_stamp",
      description: "Stamps the agent state with a marker value.",
      schema: [
        marker: [type: :string, required: true]
      ]

    @impl true
    def run(%{marker: marker}, context) do
      {:ok, %{last_marker: marker, tick: context.state.tick + 1}}
    end
  end

  defmodule BumpAction do
    @moduledoc false
    use Jido.Action,
      name: "lifecycle_bump",
      description: "Increments the tick counter without changing marker.",
      schema: []

    @impl true
    def run(_params, context), do: {:ok, %{tick: context.state.tick + 1}}
  end

  # ---------------------------------------------------------------------------
  # Test agent: the smallest possible agent that exercises the lifecycle.
  # ---------------------------------------------------------------------------

  defmodule LifecycleAgent do
    @moduledoc false
    use Jido.Agent,
      name: "foreman_lifecycle_agent",
      description: "Minimal agent for Jido.Agent lifecycle tests.",
      schema: [
        last_marker: [type: :string, default: nil],
        tick: [type: :integer, default: 0]
      ]
  end

  describe "start (new/1)" do
    test "creates an agent in the default initial state" do
      agent = LifecycleAgent.new()

      assert %Agent{} = agent
      assert agent.state.last_marker == nil
      assert agent.state.tick == 0
      refute agent.id in [nil, ""]
    end

    test "honors a caller-supplied id and initial state" do
      agent =
        LifecycleAgent.new(
          id: "lifecycle-test-1",
          state: %{last_marker: "seed", tick: 42}
        )

      assert agent.id == "lifecycle-test-1"
      assert agent.state.last_marker == "seed"
      assert agent.state.tick == 42
    end

    test "reaches a usable state — ready to accept cmd/2" do
      # "Ready" for Jido.Agent means: struct is complete, schema-valid,
      # and cmd/2 dispatch returns a struct rather than an error. We
      # don't have an explicit :ready atom — verify the readiness
      # contract by issuing one cmd and checking the result is a
      # well-formed %Agent{}.
      {agent, directives} = LifecycleAgent.cmd(LifecycleAgent.new(), BumpAction)

      assert %Agent{state: %{tick: 1}} = agent
      assert directives == []
    end
  end

  describe "cmd/2 applies action and updates state" do
    test "cmd/2 with action+params merges the result into state" do
      agent = LifecycleAgent.new(id: "cmd-params")

      {agent, directives} =
        LifecycleAgent.cmd(agent, {StampAction, %{marker: "hello"}})

      assert agent.state.last_marker == "hello"
      assert agent.state.tick == 1
      assert directives == []
    end

    test "cmd/2 with bare action module uses default params" do
      agent = LifecycleAgent.new(state: %{tick: 10})

      {agent, directives} = LifecycleAgent.cmd(agent, BumpAction)

      assert agent.state.tick == 11
      assert directives == []
    end

    test "cmd/2 is pure — caller-side struct is unchanged" do
      original = LifecycleAgent.new(state: %{tick: 7})
      same_ref = original

      {_updated, _directives} = LifecycleAgent.cmd(original, BumpAction)

      # Caller's binding must NOT have been mutated in place.
      assert original.state.tick == 7
      assert original == same_ref
    end

    test "cmd/2 chains multiple actions in order" do
      agent = LifecycleAgent.new()

      {agent, []} = LifecycleAgent.cmd(agent, {StampAction, %{marker: "first"}})
      assert agent.state.last_marker == "first"
      assert agent.state.tick == 1

      {agent, []} = LifecycleAgent.cmd(agent, BumpAction)
      assert agent.state.tick == 2

      {agent, []} = LifecycleAgent.cmd(agent, {StampAction, %{marker: "second"}})
      assert agent.state.last_marker == "second"
      assert agent.state.tick == 3
    end
  end

  describe "checkpoint (state serialization)" do
    test "checkpoint/2 produces a persistable map containing version, id, and state" do
      agent =
        LifecycleAgent.new(
          id: "checkpoint-1",
          state: %{last_marker: "snap", tick: 5}
        )

      assert {:ok, data} = LifecycleAgent.checkpoint(agent, %{})
      assert is_map(data)
      assert data.version == 1
      assert data.agent_module == LifecycleAgent
      assert data.id == "checkpoint-1"
      assert data.state.last_marker == "snap"
      assert data.state.tick == 5
    end

    test "checkpoint captures state changes produced by cmd/2" do
      agent =
        LifecycleAgent.new(id: "checkpoint-cmd")
        |> then(fn a ->
          {a, []} = LifecycleAgent.cmd(a, {StampAction, %{marker: "captured"}})
          a
        end)

      {:ok, data} = LifecycleAgent.checkpoint(agent, %{})

      assert data.id == "checkpoint-cmd"
      assert data.state.last_marker == "captured"
      assert data.state.tick == 1
    end

    test "checkpoint is deterministic for the same agent state" do
      build = fn ->
        LifecycleAgent.new(id: "det", state: %{last_marker: "d", tick: 3})
      end

      {:ok, data1} = LifecycleAgent.checkpoint(build.(), %{})
      {:ok, data2} = LifecycleAgent.checkpoint(build.(), %{})

      # version + id are stable; state equality is what callers
      # rely on for "did anything change" comparisons.
      assert data1.version == data2.version
      assert data1.id == data2.id
      assert data1.state == data2.state
    end
  end

  describe "restart (restore/2)" do
    test "restore/2 rebuilds an agent with the persisted id and state" do
      original =
        LifecycleAgent.new(
          id: "restore-1",
          state: %{last_marker: "before-crash", tick: 9}
        )

      {:ok, data} = LifecycleAgent.checkpoint(original, %{})

      assert {:ok, restored} = LifecycleAgent.restore(data, %{})
      assert %Agent{} = restored
      assert restored.id == "restore-1"
      assert restored.agent_module == LifecycleAgent
      assert restored.state.last_marker == "before-crash"
      assert restored.state.tick == 9
    end

    test "restart recovers from a checkpoint taken after cmd/2" do
      # Start, do work, checkpoint, build a fresh "second instance"
      # (mimicking process restart), restore from checkpoint.
      first =
        LifecycleAgent.new(id: "restart-cmd")
        |> then(fn a ->
          {a, []} = LifecycleAgent.cmd(a, {StampAction, %{marker: "phase-1"}})
          a
        end)

      {:ok, data} = LifecycleAgent.checkpoint(first, %{})

      # Simulate a process restart: a new struct, same id, blank state.
      # restore() must merge the persisted state back over it.
      {:ok, recovered} = LifecycleAgent.restore(data, %{})

      assert recovered.id == "restart-cmd"
      assert recovered.state.last_marker == "phase-1"
      assert recovered.state.tick == 1
    end

    test "restart accepts a checkpoint taken in one process and applies in another" do
      # The whole point of the lifecycle is that a checkpoint is a
      # value — it can outlive the process that produced it.
      task =
        Task.async(fn ->
          a = LifecycleAgent.new(id: "cross-process")
          {a, []} = LifecycleAgent.cmd(a, {StampAction, %{marker: "from-task"}})
          LifecycleAgent.checkpoint(a, %{})
        end)

      {:ok, data} = Task.await(task)

      assert {:ok, agent} = LifecycleAgent.restore(data, %{})
      assert agent.id == "cross-process"
      assert agent.state.last_marker == "from-task"
      assert agent.state.tick == 1
    end

    test "restarted agent continues to accept cmd/2" do
      a =
        LifecycleAgent.new(id: "continues")
        |> then(fn x ->
          {x, []} = LifecycleAgent.cmd(x, {StampAction, %{marker: "before"}})
          x
        end)

      {:ok, data} = LifecycleAgent.checkpoint(a, %{})
      {:ok, restored} = LifecycleAgent.restore(data, %{})

      {restored, []} = LifecycleAgent.cmd(restored, BumpAction)

      assert restored.state.tick == 2
      assert restored.state.last_marker == "before"
    end
  end

  describe "AgentServer GenServer wrapper" do
    test "start_link/1 brings up a live GenServer for the agent module" do
      # The GenServer-side lifecycle. Separate from the Agent struct
      # lifecycle above; covered here so the TRD's "start" line is
      # verifiable in its GenServer sense too.
      jido_name =
        :"foreman_jido_lifecycle_#{System.unique_integer([:positive])}"

      {:ok, jido_pid} = Jido.start_link(name: jido_name)
      on_exit(fn -> safe_stop(jido_pid) end)

      id = "agent-server-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          jido: jido_name,
          agent: LifecycleAgent,
          id: id
        )

      on_exit(fn -> safe_stop(pid, 100) end)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert AgentServer.alive?(pid)

      {:ok, %Jido.AgentServer.State{} = state} = AgentServer.state(pid)
      assert state.id == id
      assert state.agent.agent_module == LifecycleAgent
      assert state.agent.id == id
    end
  end

  # jido_pid and the AgentServer pid are both linked to this test's own
  # process (started via start_link, not start_supervised!). ExUnit tears
  # that process down before running on_exit callbacks, which cascades an
  # exit signal to both linked processes concurrently with this cleanup —
  # so by the time on_exit runs, Process.alive?/1 can still say true a
  # moment before the process actually terminates. Mirrors the safe_stop/1
  # convention already used in beads_supervisors_test.exs.
  defp safe_stop(pid, timeout \\ :infinity) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, timeout)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
