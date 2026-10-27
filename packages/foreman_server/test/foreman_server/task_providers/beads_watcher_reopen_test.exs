defmodule ForemanServer.TaskProviders.BeadsWatcherReopenTest do
  @moduledoc """
  foreman-pfta.1: re-opening a bead (`br update <id> --status=open`) after its
  task's run failed starts exactly one NEW run.

  Semantics under test (see `BeadsWatcher`'s "Re-opening a bead" section): a
  task in `failed` whose bead line is `open` and whose `updated_at` is newer than
  the task's last event is retried (`task.retry`, gateway-attested) and
  re-approved under a fresh approval. A bead line that is not newer than the
  failure is the SAME stale line the watcher already saw, so it is left alone;
  that is the guard that keeps a bead failing instantly from hot-looping.

  Real `CommandGateway`, aggregates, `ProjectionStore` and `Dispatcher`; only the
  workflow catalog is swapped (as in `beads_watcher_retry_test.exs`). The project
  path is not a git work tree, so every run the Dispatcher admits fails fast.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore}
  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TestSupport.{Eventually, RunSlotsReset}

  @await_ms 30_000

  defmodule RecordingGateway do
    @moduledoc false
    defdelegate dispatch_system(command, timeout), to: ForemanServer.CommandGateway

    def dispatch_system_approval(command, timeout) do
      send(self(), {:approval_sent, command})
      ForemanServer.CommandGateway.dispatch_system_approval(command, timeout)
    end

    def dispatch_system_retry(command, timeout) do
      send(self(), {:retry_sent, command})
      ForemanServer.CommandGateway.dispatch_system_retry(command, timeout)
    end
  end

  defmodule ImplementCatalog do
    @moduledoc false
    def type_to_workflow(_issue_type), do: {:ok, "implement"}
  end

  setup do
    RunSlotsReset.reset!()
    ensure_dispatcher_subscribed()
    on_exit(&terminate_run_executors/0)

    Eventually.put_env_for_test(:foreman_server, :command_gateway_module, RecordingGateway)
    Eventually.put_env_for_test(:foreman_server, :workflow_catalog_module, ImplementCatalog)

    suffix = System.unique_integer([:positive])
    project_id = "watcher-reopen-project-#{suffix}"
    bead_id = "watcher-reopen-bead-#{suffix}"

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "register-#{project_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.register",
               payload: %{project_id: project_id, name: "Watcher reopen", path: System.tmp_dir!()}
             })

    task_id = "beads:#{project_id}:#{bead_id}"
    state = %BeadsWatcher{project_id: project_id}

    {:ok, state: state, project_id: project_id, bead_id: bead_id, task_id: task_id}
  end

  test "reopen after a failed run dispatches a NEW run, once, and again after the next failure",
       %{state: state, bead_id: bead_id, task_id: task_id} do
    # First dispatch from a bead created `open` (no updated_at needed).
    assert :imported = BeadsWatcher.process_line(state, line(bead_id, "2020-01-01T00:00:00Z"))
    assert_received {:approval_sent, first}
    first_run = fail_and_settle(task_id)
    assert first.command_id == "beads-cmd:#{state.project_id}:#{bead_id}:auto-approve"

    # A poll of the unchanged bead line (older than the failure) is a no-op.
    assert :reconciled = BeadsWatcher.process_line(state, line(bead_id, "2020-01-01T00:00:00Z"))
    refute_received {:retry_sent, _}
    assert approved_run_ids(task_id) == [first_run]

    # The operator re-opens the bead: updated_at is after the failure.
    reopen_1 = line(bead_id, after_last_event(task_id))
    assert :imported = BeadsWatcher.process_line(state, reopen_1)
    assert_received {:retry_sent, retry_1}
    assert retry_1.command_id == "beads-cmd:#{state.project_id}:#{bead_id}:retry-1"
    assert_received {:approval_sent, second}
    assert second.command_id == "beads-cmd:#{state.project_id}:#{bead_id}:auto-approve:retry-1"

    second_run = bound_run_id(task_id)
    assert second_run != first_run
    assert approved_run_ids(task_id) == [first_run, second_run]

    # The new run fails fast. Replaying the SAME reopen line (second poll, or a
    # bead that keeps failing instantly) must not retry again.
    settle_failed(task_id, second_run)
    assert :reconciled = BeadsWatcher.process_line(state, reopen_1)
    assert :reconciled = BeadsWatcher.process_line(state, reopen_1)
    refute_received {:retry_sent, _}
    assert approved_run_ids(task_id) == [first_run, second_run]

    # Re-opened again after the second failure: retries again.
    assert :imported = BeadsWatcher.process_line(state, line(bead_id, after_last_event(task_id)))
    assert_received {:retry_sent, retry_2}
    assert retry_2.command_id == "beads-cmd:#{state.project_id}:#{bead_id}:retry-2"
    third_run = bound_run_id(task_id)
    assert third_run not in [first_run, second_run]
    assert approved_run_ids(task_id) == [first_run, second_run, third_run]
  end

  test "the same reopen delivered twice before the new run settles makes one retry",
       %{state: state, bead_id: bead_id, task_id: task_id} do
    assert :imported = BeadsWatcher.process_line(state, line(bead_id, "2020-01-01T00:00:00Z"))
    first_run = fail_and_settle(task_id)
    reopen = line(bead_id, after_last_event(task_id))

    assert :imported = BeadsWatcher.process_line(state, reopen)
    # Whatever the new run is doing now (starting, running, already failed),
    # a second delivery of the same line must not retry or approve again.
    assert :reconciled = BeadsWatcher.process_line(state, reopen)

    assert [^first_run, second_run] = approved_run_ids(task_id)
    assert second_run != first_run
  end

  defp line(bead_id, updated_at) do
    Jason.encode!(%{
      "id" => bead_id,
      "title" => "A bead whose runs fail",
      "status" => "open",
      "issue_type" => "task",
      "labels" => ["foreman-exec"],
      "updated_at" => updated_at
    })
  end

  # Waits for the dispatched run to fail the task and returns that run's id.
  defp fail_and_settle(task_id) do
    task = await_task(task_id, "the run to fail the task", &(&1.status == "failed"))
    settle_failed(task_id, task.run_id)
    task.run_id
  end

  defp settle_failed(task_id, run_id) do
    await_task(
      task_id,
      "the run to fail the task",
      &(&1.status == "failed" and &1.run_id == run_id)
    )

    await_run_terminal(run_id)
  end

  # What `br` stamps when the operator re-opens the bead now: the wall clock,
  # which is after the failure the operator is reacting to (and, being taken
  # before the retry, before the next failure). Never earlier than the last event.
  defp after_last_event(task_id) do
    last_event_ms = ProjectionStore.task_projection(task_id).last_event_at_ms

    max(System.system_time(:millisecond), last_event_ms + 1)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp bound_run_id(task_id) do
    task =
      await_task(task_id, "a run bound", &(is_binary(&1.run_id) and &1.status != "open"))

    task.run_id
  end

  defp approved_run_ids(task_id) do
    {:ok, events} = EventStore.read_stream_forward("task:" <> task_id, 0, 10_000)

    for %{event_type: "TaskApproved", data: data} <- events, do: Map.fetch!(data, :run_id)
  end

  defp await_task(task_id, what, predicate) do
    Eventually.await(
      fn ->
        case ProjectionStore.task_projection(task_id) do
          nil -> nil
          task -> if(predicate.(task), do: task)
        end
      end,
      timeout: @await_ms,
      interval: 25,
      message: what
    )
  end

  defp await_run_terminal(run_id) do
    Eventually.await(
      fn -> match?(%{terminal?: true}, ProjectionStore.run(run_id)) end,
      timeout: @await_ms,
      interval: 25,
      message: "run #{run_id} to reach a terminal state"
    )
  end

  defp ensure_dispatcher_subscribed do
    case Process.whereis(ForemanServer.Workflow.Dispatcher) do
      pid when is_pid(pid) ->
        :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
          %{state | subscribers: Map.put(state.subscribers, pid, true)}
        end)

      nil ->
        flunk("ForemanServer.Workflow.Dispatcher is not running; the test needs it to dispatch")
    end
  end

  defp terminate_run_executors do
    case Process.whereis(ForemanServer.Workflow.RunSupervisor) do
      nil ->
        :ok

      supervisor ->
        for {_id, pid, _type, _modules} <- ForemanServer.Workflow.RunSupervisor.which_runs(),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(supervisor, pid)

        :ok
    end
  end
end
