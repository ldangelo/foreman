defmodule ForemanServer.TaskProviders.BeadsWatcherRetryTest do
  @moduledoc """
  foreman-nfizr. After a terminal run the operator's `task.retry` returns the task to
  `open`, and the watcher's next rescan re-approves it (`check_dedupe/2` →
  `{:retry_approval, ...}`). That approval must be a NEW one — a new `approval_id`, and
  so a new run id — not a replay of the original `TaskApproved`.

  An approval's identity IS its `command_id` (`approval_id == command_id`, and
  `Identity.run_id/2` derives the run from it), and `command_id` is also the aggregate
  actor's idempotency key. The watcher used one deterministic id per bead for every
  approval, so the re-approval was answered from the event stream with the ORIGINAL
  `TaskApproved` (same run id as the failed run) and appended nothing: the projection
  stayed `open` with no run bound, while the watcher reported `:imported`.

  These tests run the real `CommandGateway`, aggregates, `ProjectionStore` and
  `Dispatcher`. Only the workflow catalog is swapped (the fixture catalog maps no bead
  `issue_type`), and the gateway is wrapped to record the approval the watcher sent.
  The project path is not a git work tree, so every run the Dispatcher admits fails in
  its first phase — which is the "failed run" the operator then retries.
  """
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore}
  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TestSupport.{Eventually, RunSlotsReset}

  @await_ms 30_000

  defmodule RecordingGateway do
    @moduledoc false
    # The real gateway, plus a message to the calling process for every approval the watcher
    # sends. `BeadsWatcher.process_line/2` runs in the test process, so `self()` is the test.
    defdelegate dispatch_system(command, timeout), to: ForemanServer.CommandGateway

    def dispatch_system_approval(command, timeout) do
      send(self(), {:approval_sent, command})
      ForemanServer.CommandGateway.dispatch_system_approval(command, timeout)
    end
  end

  defmodule ImplementCatalog do
    @moduledoc false
    # The fixture catalog declares no `task_types:`, so no bead `issue_type` maps through it.
    # `implement` is the one workflow the fixture catalog does load.
    def type_to_workflow(_issue_type), do: {:ok, "implement"}
  end

  setup do
    # Same isolation `dispatcher_bridge_test.exs` and `full_workflow_lifecycle_test.exs` use
    # for the wired Dispatcher: the process-wide `run_slots:global` aggregate is reset, and
    # the Dispatcher's ProjectionStore subscription is re-asserted because an earlier test's
    # bare `ProjectionStoreReset.reset!()` drops it for the rest of the run.
    RunSlotsReset.reset!()
    ensure_dispatcher_subscribed()
    on_exit(&terminate_run_executors/0)

    Eventually.put_env_for_test(:foreman_server, :command_gateway_module, RecordingGateway)
    Eventually.put_env_for_test(:foreman_server, :workflow_catalog_module, ImplementCatalog)

    suffix = System.unique_integer([:positive])
    project_id = "watcher-retry-project-#{suffix}"
    bead_id = "watcher-retry-bead-#{suffix}"

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "register-#{project_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.register",
               payload: %{project_id: project_id, name: "Watcher retry", path: System.tmp_dir!()}
             })

    %{
      project_id: project_id,
      bead_id: bead_id,
      task_id: "beads:#{project_id}:#{bead_id}",
      state: %BeadsWatcher{project_id: project_id},
      bead_line:
        Jason.encode!(%{
          "id" => bead_id,
          "title" => "A bead whose first run fails",
          "status" => "open",
          "issue_type" => "task",
          "labels" => ["foreman-exec"]
        })
    }
  end

  test "a retried task is re-approved under a fresh approval and dispatches a NEW run",
       %{
         state: state,
         bead_line: line,
         task_id: task_id,
         project_id: project_id,
         bead_id: bead_id
       } do
    # First dispatch: the normal path. Its approval keeps the deterministic per-bead id.
    assert :imported = BeadsWatcher.process_line(state, line)
    assert_received {:approval_sent, first_approval}

    assert first_approval.command_id ==
             "beads-cmd:#{project_id}:#{bead_id}:auto-approve"

    %{run_id: failed_run_id, approval_id: first_approval_id} =
      ProjectionStore.task_projection(task_id)

    assert first_approval_id == first_approval.command_id

    # The run fails (nothing in the project path is a git work tree), and the task with it.
    await_task(task_id, "the first run to fail the task", &(&1.status == "failed"))
    await_run_terminal(failed_run_id)

    # The operator retries: the task is `open` again with no run bound.
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "retry-#{task_id}",
               aggregate_id: "task:#{task_id}",
               type: "task.retry",
               payload: %{task_id: task_id, reason: "operator retry"}
             })

    assert %{status: "open", run_id: nil, approval_id: nil} =
             ProjectionStore.task_projection(task_id)

    # The watcher's next rescan of the same bead line re-approves it.
    assert :imported = BeadsWatcher.process_line(state, line)
    assert_received {:approval_sent, retry_approval}

    # Fresh approval: the task left `open` bound to a run that is not the failed one.
    task = ProjectionStore.task_projection(task_id)

    assert task.status != "open",
           "the retried task is still `open`: the watcher's approval was a replay of the " <>
             "original TaskApproved, so nothing was appended (#{inspect(task)})"

    assert is_binary(task.run_id) and task.run_id != failed_run_id
    assert task.approval_id == retry_approval.command_id
    assert retry_approval.command_id != first_approval.command_id

    # ...and that new run is the one the Dispatcher admits and starts.
    new_run = Eventually.await(fn -> ProjectionStore.run(task.run_id) end, timeout: @await_ms)
    assert new_run.task_id == task_id
    await_run_terminal(task.run_id)

    # The event stream holds exactly two approvals, one per attempt, binding different runs.
    assert approved_run_ids(task_id) == [failed_run_id, task.run_id]

    # The same retry delivered again is the same command, so it appends nothing.
    assert {:ok, _} = CommandGateway.dispatch_system_approval(retry_approval, 5_000)
    assert approved_run_ids(task_id) == [failed_run_id, task.run_id]
    assert %{run_id: bound_run_id} = ProjectionStore.task_projection(task_id)
    assert bound_run_id == task.run_id
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
          task -> if predicate.(task), do: task
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
