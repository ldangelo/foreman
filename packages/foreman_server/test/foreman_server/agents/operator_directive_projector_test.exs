defmodule ForemanServer.Agents.OperatorDirectiveProjectorTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.OperatorDirectiveProjector` —
  the JSI-T008 projector that converts `InboxItemStarted` events
  (source: `OperatorQuestionSource`) into Jido directives published
  on the `agents.<agent_id>.directive` topic.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Agents.OperatorDirectiveProjector
  alias ForemanServer.Inbox.{DedupeTable, Poller, InboxItemStarted}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)

    case Process.whereis(DedupeTable) do
      nil -> {:ok, _} = DedupeTable.start_link([])
      _ -> :ok
    end

    case Process.whereis(Poller) do
      nil -> {:ok, _} = Poller.start_link([])
      _ -> :ok
    end

    :ok
  end

  setup do
    DedupeTable.clear()
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    # Detach the projector handler if it was attached by a prior
    # test, so each test starts with a clean attachment state.
    Poller.detach_handler(OperatorQuestionSource)
    :ok
  end

  describe "build_directive/1" do
    test "returns the agents.<agent_id>.directive signal built from an InboxItemStarted" do
      event = %InboxItemStarted{
        correlation_id: "q-200",
        source: OperatorQuestionSource,
        payload: %{
          "question_id" => "q-200",
          "question" => "what's next?",
          "agent_id" => "agent-9"
        },
        timestamp: 1_700_000_000
      }

      signal = OperatorDirectiveProjector.build_directive(event)

      assert signal.type == "agents.agent-9.directive"
      assert signal.data["query_id"] == "q-200"
      assert signal.data["question"] == "what's next?"
    end

    test "returns nil for an InboxItemStarted without an agent_id" do
      event = %InboxItemStarted{
        correlation_id: "q-201",
        source: OperatorQuestionSource,
        payload: %{"question_id" => "q-201", "question" => "no agent"},
        timestamp: 1_700_000_001
      }

      assert is_nil(OperatorDirectiveProjector.build_directive(event))
    end
  end

  describe "publish/2 (end-to-end InboxItemStarted → directive on bus)" do
    test "publishes a Jido signal on the agents.<agent_id>.directive topic" do
      bus_name = :"TestProjectorBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      event = %InboxItemStarted{
        correlation_id: "q-300",
        source: OperatorQuestionSource,
        payload: %{
          "question_id" => "q-300",
          "question" => "what's the next step?",
          "agent_id" => "agent-7",
          "options" => %{"timeout_ms" => 30_000}
        },
        timestamp: 1_700_000_002
      }

      assert {:ok, [recorded]} = OperatorDirectiveProjector.publish(event, bus_name)
      assert recorded.type == "agents.agent-7.directive"
      assert recorded.signal.data["query_id"] == "q-300"
      assert recorded.signal.data["question"] == "what's the next step?"
      assert recorded.signal.data["options"] == %{"timeout_ms" => 30_000}
    end

    test "returns :skipped for an event without an agent_id" do
      event = %InboxItemStarted{
        correlation_id: "q-301",
        source: OperatorQuestionSource,
        payload: %{"question_id" => "q-301"},
        timestamp: 1_700_000_003
      }

      assert :skipped = OperatorDirectiveProjector.publish(event)
    end
  end

  describe "start_link/1 wires the projector to the Inbox Poller" do
    test "start_link/1 attaches the projector as a Poller handler" do
      name = :"TestProjector.#{:erlang.unique_integer()}"

      start_supervised!(
        {OperatorDirectiveProjector, [name: name]},
        id: :test_projector
      )

      # Production invariant: the projector must be in the Poller's
      # handlers list with the right source/handler pair.
      handlers = Poller.handlers()

      assert Enum.any?(handlers, fn {src, {handler, _pid}} ->
               src == OperatorQuestionSource and
                 handler == :operator_directive_projector
             end)
    end

    test "handle_info/2 with the live Poller tuple does not crash the GenServer" do
      name = :"TestProjector.#{:erlang.unique_integer()}"

      start_supervised!(
        {OperatorDirectiveProjector, [name: name]},
        id: :test_projector
      )

      projector_pid = Process.whereis(name)

      event = %InboxItemStarted{
        correlation_id: "q-poller-1",
        source: OperatorQuestionSource,
        payload: %{
          "question_id" => "q-poller-1",
          "question" => "live tuple",
          "agent_id" => "agent-live"
        },
        timestamp: 1_700_000_004
      }

      # The live Poller dispatches {:inbox_item_started, handler, item}.
      # The projector's handle_info must accept that tuple, build the
      # signal, and call publish/2 without crashing. (publish/2 will
      # fail with :noproc because the production bus isn't started in
      # this test scope, but that's a logged warning, not a crash.)
      send(projector_pid, {:inbox_item_started, :operator_directive_projector, event})

      # Give the GenServer a moment to process the message.
      Process.sleep(50)

      # The GenServer must still be alive after the message.
      assert Process.alive?(projector_pid)
    end
  end
end
