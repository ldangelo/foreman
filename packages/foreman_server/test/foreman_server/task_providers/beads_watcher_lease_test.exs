defmodule ForemanServer.TaskProviders.BeadsWatcherLeaseTest do
  @moduledoc """
  TRD-010-TEST: proves `BeadsWatcher`'s boot-replay/catch-up-tail lease
  acquisition (`with_beads_lease/2`) actually serializes against a
  concurrent lease holder using the real `BeadsDbLease` aggregate — the
  same one `ForemanServer.TaskProviders.BeadsAdapter` wraps every
  `RunExecutor`-dispatched `br update` in (`claim/3`, `complete/3`,
  `fail/3`).

  Ordering is proven via an `Agent`-backed event log rather than raw
  timestamps: `Agent.update/2` calls are serialized by the agent's own
  mailbox, so the list order in the agent's final state IS the real
  cross-process temporal order — no wall-clock comparison needed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TaskProviders.BeadsWatcher

  @moduletag :tmp_dir

  # Sleeps while "dispatching" so the watcher holds the lease across a
  # window wide enough for the concurrent runner to attempt (and be
  # forced to queue for) the same lease.
  defmodule SlowFakeCommandGateway do
    @moduledoc false
    def dispatch_system(_command, _timeout) do
      # Tell the test the watcher is now inside its (slow) dispatch, i.e. it
      # already holds the lease.
      {test_pid, order_agent} = :persistent_term.get({__MODULE__, :notify})
      Agent.update(order_agent, &[:watcher_dispatch_start | &1])
      send(test_pid, :gateway_dispatching)

      Process.sleep(150)

      # Still inside the watcher's lease window: the lease is released only
      # after this returns, so the runner cannot have started holding yet.
      Agent.update(order_agent, &[:watcher_dispatch_end | &1])
      {:ok, nil}
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)
  end

  defmodule NilProjectionStore do
    @moduledoc false
    def get_task(_opts), do: nil
  end

  defmodule GenericWorkflowCatalog do
    @moduledoc false
    def type_to_workflow(_issue_type), do: {:ok, "generic"}
  end

  setup do
    original_cg =
      Application.get_env(:foreman_server, :command_gateway_module, ForemanServer.CommandGateway)

    original_ps =
      Application.get_env(
        :foreman_server,
        :projection_store_module,
        ForemanServer.ProjectionStore
      )

    original_wc =
      Application.get_env(
        :foreman_server,
        :workflow_catalog_module,
        ForemanServer.Workflow.Catalog
      )

    Application.put_env(:foreman_server, :command_gateway_module, SlowFakeCommandGateway)
    Application.put_env(:foreman_server, :projection_store_module, NilProjectionStore)
    Application.put_env(:foreman_server, :workflow_catalog_module, GenericWorkflowCatalog)

    on_exit(fn ->
      Application.put_env(:foreman_server, :command_gateway_module, original_cg)
      Application.put_env(:foreman_server, :projection_store_module, original_ps)
      Application.put_env(:foreman_server, :workflow_catalog_module, original_wc)
    end)

    :ok
  end

  test "watcher boot_replay and a concurrent RunExecutor-style br update serialize through BeadsDbLease, never interleaving",
       %{tmp_dir: tmp_dir} do
    database_path =
      Path.join(tmp_dir, "lease-test-#{System.unique_integer([:positive, :monotonic])}.db")

    jsonl_path = Path.join(tmp_dir, "issues.jsonl")

    File.write!(
      jsonl_path,
      ~s({"id":"bead-lease","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)
    )

    state = %BeadsWatcher{
      project_id: "proj-lease",
      jsonl_path: jsonl_path,
      database_path: database_path,
      poll_ms: 1_000
    }

    {:ok, order_agent} = Agent.start_link(fn -> [] end)
    :persistent_term.put({SlowFakeCommandGateway, :notify}, {self(), order_agent})
    on_exit(fn -> :persistent_term.erase({SlowFakeCommandGateway, :notify}) end)

    on_exit(fn -> if Process.alive?(order_agent), do: Agent.stop(order_agent) end)

    watcher_task =
      Task.async(fn ->
        Agent.update(order_agent, &[:watcher_start | &1])
        BeadsWatcher.boot_replay(state)
        Agent.update(order_agent, &[:watcher_end | &1])
      end)

    # Wait until the watcher holds the lease and is inside its (slow)
    # dispatch before the concurrent runner attempts the same lease.
    assert_receive :gateway_dispatching, 5_000

    runner_task =
      Task.async(fn ->
        Agent.update(order_agent, &[:runner_attempt | &1])

        {:ok, :runner_done} =
          BeadsDbLease.with_lease(
            database_path,
            "run-concurrent",
            "task-concurrent",
            fn ->
              Agent.update(order_agent, &[:runner_holding | &1])
              {:ok, :runner_done}
            end
          )

        Agent.update(order_agent, &[:runner_released | &1])
      end)

    Task.await(watcher_task, 5_000)
    Task.await(runner_task, 5_000)

    events = Agent.get(order_agent, &Enum.reverse/1)

    # `:watcher_end` is logged after the lease is released, so the runner (queued
    # behind it) can legitimately log `:runner_holding` first; the deterministic
    # evidence of the watcher's lease window is the end of its slow dispatch.
    watcher_end_index = Enum.find_index(events, &(&1 == :watcher_dispatch_end))
    runner_holding_index = Enum.find_index(events, &(&1 == :runner_holding))

    refute is_nil(watcher_end_index), "watcher never completed: #{inspect(events)}"
    refute is_nil(runner_holding_index), "runner never acquired the lease: #{inspect(events)}"

    # The runner could only start HOLDING the lease after the watcher
    # finished its work inside the lease — proving the two never interleaved
    # their reads/writes against the same database_path.
    assert watcher_end_index < runner_holding_index, inspect(events)

    # The runner did attempt while the watcher was still mid-flight —
    # proving this is a genuine queue-and-wait, not an accidental
    # sequential run.
    runner_attempt_index = Enum.find_index(events, &(&1 == :runner_attempt))
    assert runner_attempt_index < watcher_end_index, inspect(events)
  end

  # foreman-w29up / foreman-3ll3t: after a restart the watcher logged
  # "lease_acquire failed reason=:lease_timeout, skipping this read cycle" on every
  # poll and imported nothing, because the server that was killed inside its own
  # pass had left its `watcher:<project>:<ns>` hold in the event store.
  test "boot_replay after a restart is not made to skip its read cycle by a hold the killed server left",
       %{tmp_dir: tmp_dir} do
    database_path =
      Path.join(tmp_dir, "stranded-#{System.unique_integer([:positive, :monotonic])}.db")

    stream = BeadsDbLease.stream_id(database_path)
    on_exit(fn -> _ = Store.delete_stream(stream, :any_version, :hard) end)

    jsonl_path = Path.join(tmp_dir, "issues.jsonl")

    File.write!(
      jsonl_path,
      ~s({"id":"bead-stranded","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)
    )

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "lease.acquire",
               command_id: "test:stranded-watcher-hold:#{stream}",
               aggregate_id: stream,
               payload: %{
                 db_path: database_path,
                 run_id: "watcher:proj-lease:1",
                 task_id: "watcher:proj-lease:1",
                 acquired_at_ms: System.system_time(:millisecond),
                 incarnation: "incarnation-of-the-killed-server"
               }
             })

    # The restart: the aggregate actor is rebuilt from the event store.
    :ok = Supervisor.terminate_child(ForemanServer.Aggregator, stream)
    :ok = Supervisor.delete_child(ForemanServer.Aggregator, stream)

    {:ok, order_agent} = Agent.start_link(fn -> [] end)
    :persistent_term.put({SlowFakeCommandGateway, :notify}, {self(), order_agent})
    on_exit(fn -> :persistent_term.erase({SlowFakeCommandGateway, :notify}) end)
    on_exit(fn -> if Process.alive?(order_agent), do: Agent.stop(order_agent) end)

    state = %BeadsWatcher{
      project_id: "proj-lease",
      jsonl_path: jsonl_path,
      database_path: database_path,
      poll_ms: 1_000
    }

    log = capture_log(fn -> BeadsWatcher.boot_replay(state) end)

    # `boot_replay/1` runs in this process, so the bead's task.create dispatch is
    # already in the mailbox if (and only if) the pass got the lease.
    assert_received :gateway_dispatching
    refute log =~ "lease_acquire failed"
  end
end
