defmodule ForemanServer.Agents.OperatorQuestionFlowTest do
  @moduledoc """
  Integration test for the operator question end-to-end flow
  (TRD-2026-4212be7e, JSI-T010):

    1. OperatorQuestionDispatcher.dispatch/1 (JSI-T007) calls
       SharedInbox.ingest/2 with OperatorQuestionSource.
    2. SharedInbox.ingest/2 writes an InboxItemStarted event and
       casts to the Foreman Inbox Poller.
    3. OperatorDirectiveProjector (JSI-T008) is a Poller handler;
       its handle_info/2 calls build_directive/1 + publish/2.
    4. SignalDirectivePublisher.publish/3 (JSI-T011) publishes
       the Jido signal on the agents.<agent_id>.directive topic.

  This test wires all of these together end-to-end. The recorder
  subscribes via `self()` and `assert_receive` (an Agent process
  doesn't auto-record incoming messages).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionDispatcher
  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Agents.OperatorDirectiveProjector
  alias ForemanServer.Inbox.{DedupeTable, Poller}

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
    Poller.detach_handler(OperatorQuestionSource)
    :ok
  end

  test "operator question → inbox → projector → directive on bus" do
    bus_name = :"IntegrationBus.#{:erlang.unique_integer()}"
    {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

    # Subscribe self() to the directive bus so we can
    # assert_receive. (Agent doesn't auto-record messages.)
    {:ok, _ref} =
      Jido.Signal.Bus.subscribe(bus_name, "agents.*.directive", dispatch: {:pid, target: self()})

    # Start the projector (it attaches itself to the Poller).
    projector_name = :"IntegrationProjector.#{:erlang.unique_integer()}"

    {:ok, _projector_pid} =
      OperatorDirectiveProjector.start_link(name: projector_name, bus: bus_name)

    payload = %{
      "question_id" => "q-int-1",
      "question" => "what is the next step?",
      "agent_id" => "agent-int-1",
      "options" => %{"timeout_ms" => 30_000}
    }

    assert {:ok, :started, _item} = OperatorQuestionDispatcher.dispatch(payload)

    # Wait for the directive to land. The Poller dispatches via
    # cast (async) and the projector publishes via Jido.Bus.publish/2
    # which is also async. assert_receive with a generous timeout.
    assert_receive {:signal, %Jido.Signal{} = signal}, 2_000

    assert signal.type == "agents.agent-int-1.directive"
    assert signal.data["query_id"] == "q-int-1"
    assert signal.data["question"] == "what is the next step?"
    assert signal.data["options"] == %{"timeout_ms" => 30_000}
  end
end
