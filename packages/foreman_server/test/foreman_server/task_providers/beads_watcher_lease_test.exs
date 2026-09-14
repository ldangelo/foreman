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

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.TaskProviders.BeadsWatcher

  @moduletag :tmp_dir

  # Sleeps while "dispatching" so the watcher holds the lease across a
  # window wide enough for the concurrent runner to attempt (and be
  # forced to queue for) the same lease.
  defmodule SlowFakeCommandGateway do
    @moduledoc false
    def dispatch_system(_command, _timeout) do
      Process.sleep(150)
      {:ok, nil}
    end
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
    File.write!(jsonl_path, ~s({"id":"bead-lease","title":"x","issue_type":"task","status":"open"}\n))

    state = %BeadsWatcher{
      project_id: "proj-lease",
      jsonl_path: jsonl_path,
      database_path: database_path,
      file_handle: nil,
      read_offset: 0,
      partial_line: "",
      poll_ms: 1_000
    }

    {:ok, order_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(order_agent), do: Agent.stop(order_agent) end)

    watcher_task =
      Task.async(fn ->
        # `:raw` file handles are process-bound in Erlang — open it
        # inside the spawned task itself, not the test process, or
        # reads fail with :not_on_controlling_process.
        {:ok, handle} = :file.open(jsonl_path, [:read, :binary, :raw])
        state = %{state | file_handle: handle}
        Agent.update(order_agent, &[:watcher_start | &1])
        BeadsWatcher.boot_replay(state)
        Agent.update(order_agent, &[:watcher_end | &1])
        :file.close(handle)
      end)

    # Give the watcher time to acquire the lease and enter its (slow)
    # dispatch before the concurrent runner attempts the same lease.
    Process.sleep(40)

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

    watcher_end_index = Enum.find_index(events, &(&1 == :watcher_end))
    runner_holding_index = Enum.find_index(events, &(&1 == :runner_holding))

    refute is_nil(watcher_end_index), "watcher never completed: #{inspect(events)}"
    refute is_nil(runner_holding_index), "runner never acquired the lease: #{inspect(events)}"

    # The runner could only start HOLDING the lease after the watcher
    # released it — proving the two never interleaved their reads/writes
    # against the same database_path.
    assert watcher_end_index < runner_holding_index, inspect(events)

    # The runner did attempt while the watcher was still mid-flight —
    # proving this is a genuine queue-and-wait, not an accidental
    # sequential run.
    runner_attempt_index = Enum.find_index(events, &(&1 == :runner_attempt))
    assert runner_attempt_index < watcher_end_index, inspect(events)
  end
end
