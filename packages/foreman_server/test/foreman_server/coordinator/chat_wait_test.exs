defmodule ForemanServer.Coordinator.ChatWaitTest do
  @moduledoc """
  `foreman project chat` waits until the coordinator is idle again. Between two
  turns the status is `idle` while the operator's next message is still pending;
  the page must say so (`pending_messages`) or the CLI exits before the answer.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Agent.Stub, Turn}
  alias ForemanServer.CoordinatorAPI

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreadActions, FakeThreads, SpyGateway}

  defmodule HoldSecondTurnGateway do
    @moduledoc "Executes everything except the `turn.start` for message m2, which it holds until released."
    alias ForemanServer.TestSupport.CoordinatorHelpers.SpyGateway

    def dispatch_system(
          %{type: "coordinator.turn.start", payload: %{trigger_message_ids: ["m2"]}} = command
        ) do
      send(:persistent_term.get({SpyGateway, :pid}), {:held_start, self()})

      receive do
        :release_start -> SpyGateway.dispatch_system(command)
      end
    end

    def dispatch_system(command), do: SpyGateway.dispatch_system(command)
    def dispatch_system_approval(command), do: SpyGateway.dispatch_system_approval(command)
  end

  setup %{tmp_dir: dir} do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

    project_id = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])
    H.subscribe!()

    on_exit(fn ->
      SpyGateway.unwatch()
      FakeThreads.clear()
      FakeThreadActions.clear()
    end)

    {:ok, project_id: project_id}
  end

  defp start_runtime(project_id, script) do
    name = :"co_rt_chat_wait_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      agent: Stub,
      agent_opts: [script: script],
      only: [project_id],
      gateway: HoldSecondTurnGateway,
      threads: FakeThreads,
      thread_actions: FakeThreadActions,
      retry_backoff_ms: 0,
      backfill?: false
    ]

    start_supervised!(
      Supervisor.child_spec({ForemanServer.Coordinator.Supervisor, opts}, id: name)
    )
  end

  defp say(project_id, message_id, text) do
    {:ok, %{seq: seq}} =
      CoordinatorAPI.post_message(project_id, %{
        text: text,
        source: "cli",
        message_id: message_id
      })

    seq
  end

  defp completed(project_id, message_id) do
    H.await_event(
      "CoordinatorTurnCompleted",
      &(&1.project_id == project_id and &1.cursor_message_id == message_id)
    )
  end

  test "the page reports the pending message between the turns, so 'idle' does not end the wait",
       %{project_id: p} do
    test_pid = self()

    first_turn = fn _context ->
      send(test_pid, {:turn_open, self()})

      receive do
        :release_turn -> {:ok, %Turn{reply: "about m1", actions: []}}
      end
    end

    script = start_supervised!({Stub, responses: [first_turn, {:ok, %Turn{reply: "about m2"}}]})
    start_runtime(p, script)

    say(p, "m1", "first")
    assert_receive {:turn_open, turn_pid}, 10_000

    seq_m2 = say(p, "m2", "second")

    send(turn_pid, :release_turn)
    assert %{cursor_message_id: "m1"} = completed(p, "m1")
    assert_receive {:held_start, worker}, 10_000

    # T1 is done and T2 has not started: the window the CLI mistook for "done".
    assert {:ok, page} = CoordinatorAPI.read_page(p, after: seq_m2)
    assert page["status"] == "idle"
    assert page["pending_messages"] == 1
    assert [%{"text" => "about m1"}] = page["messages"]

    send(worker, :release_start)
    assert %{cursor_message_id: "m2"} = completed(p, "m2")

    assert {:ok, page} = CoordinatorAPI.read_page(p, after: seq_m2)
    assert page["status"] == "idle"
    assert page["pending_messages"] == 0
    assert ["about m1", "about m2"] = Enum.map(page["messages"], & &1["text"])
  end
end
