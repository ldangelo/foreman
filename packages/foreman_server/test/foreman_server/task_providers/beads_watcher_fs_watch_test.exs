defmodule ForemanServer.TaskProviders.BeadsWatcherFsWatchTest do
  @moduledoc """
  TRD-011-TEST: proves the `file_system` watch added in TRD-011 is
  actually the primary (<1s) trigger for a newly-written JSONL line —
  not an accident of the periodic poll — and that the poll remains a
  working backstop when a watch notification is (simulated as)
  missed.

  Boots a real supervised `BeadsWatcher` process (`start_link/1`), like
  `beads_watcher_boot_test.exs`, because both the `file_system`
  subscription (done in `init/1`) and the debounce timer
  (`handle_info/2`) are process-local mechanics that a hand-built
  state plus a pure function call cannot exercise.

  Malformed-line cases prove "a line got read and processed" without
  faking dispatch collaborators; live-tail dispatch cases write valid
  Beads lines and assert `task.create`/`task.approve` are dispatched by
  the already-running watcher, without relying on boot replay or restart.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TaskProviders.BrRunnerMock

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule FakeCommandGateway do
    @moduledoc false

    def reset, do: :persistent_term.put({__MODULE__, :calls}, [])
    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])

    def dispatch_system(command, timeout) do
      prev = :persistent_term.get({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :calls}, prev ++ [{command, timeout}])
      {:ok, nil}
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)
  end

  defmodule FakeProjectionStore do
    @moduledoc false
    def get_task(external_id: bead_id) when is_binary(bead_id), do: nil
  end

  defmodule FakeWorkflowCatalog do
    @moduledoc false
    def type_to_workflow(_issue_type), do: {:ok, "generic"}
  end

  setup do
    original_cg = Application.fetch_env(:foreman_server, :command_gateway_module)
    original_ps = Application.fetch_env(:foreman_server, :projection_store_module)
    original_wc = Application.fetch_env(:foreman_server, :workflow_catalog_module)

    Application.put_env(:foreman_server, :command_gateway_module, FakeCommandGateway)
    Application.put_env(:foreman_server, :projection_store_module, FakeProjectionStore)
    Application.put_env(:foreman_server, :workflow_catalog_module, FakeWorkflowCatalog)
    FakeCommandGateway.reset()

    on_exit(fn ->
      restore_env(:command_gateway_module, original_cg)
      restore_env(:projection_store_module, original_ps)
      restore_env(:workflow_catalog_module, original_wc)
      FakeCommandGateway.reset()
    end)

    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:foreman_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:foreman_server, key)

  defp sync_status_response(coverage_drift) do
    body = %{
      "coverage_drift" => coverage_drift,
      "coverage" => %{"db_exportable_issues" => 0, "jsonl_unique_ids" => 0},
      "dirty_count" => 0
    }

    {:ok, %{stdout: Jason.encode!(body), stderr: "", exit_code: 0}}
  end

  defp where_response(jsonl_path) do
    {:ok, %{stdout: Jason.encode!(%{"jsonl_path" => jsonl_path}), stderr: "", exit_code: 0}}
  end

  # Boots a real supervised watcher against `tmp_dir`, stubbing the two
  # `BrRunner` calls `init/1` makes during preflight
  # (coverage-drift check, then jsonl_path resolution) — mirrors
  # `beads_watcher_boot_test.exs`'s "resumes normally" setup.
  defp boot_watcher(project_id, tmp_dir, jsonl_path, extra_opts) do
    expect(BrRunnerMock, :cmd, fn {:sync_status, %{flags: ["--status"]}},
                                  _project_config,
                                  _opts ->
      sync_status_response(false)
    end)

    expect(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _project_config, _opts
                                  when db_path == tmp_dir ->
      where_response(jsonl_path)
    end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      BeadsWatcher.start_link([project_id: project_id, database_path: tmp_dir] ++ extra_opts)

    pid
  end

  defp unique_handler(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp attach_malformed(handler_id, test_pid, ref) do
    :telemetry.attach(
      handler_id,
      [:foreman_server, :task_provider, :beads, :watcher, :malformed],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, metadata})
      end,
      nil
    )

    on_exit(fn ->
      try do
        :telemetry.detach(handler_id)
      rescue
        _ -> :ok
      end
    end)
  end

  # Writes a throwaway line and waits for the watcher to emit
  # `[:watcher, :malformed]` for it, retrying with a fresh write up to
  # `attempts` times (each with a generous per-attempt budget) before
  # failing. `file_system` delivery is real OS-level IPC to a native
  # listener process: its own startup (spawning the port process,
  # registering with the platform's file-event API) happens
  # asynchronously after `FileSystem.start_link/1` returns, so a write
  # immediately after boot can race ahead of it and be silently missed
  # — not merely delayed. On a loaded machine, even a "hot" listener
  # can occasionally coalesce or delay a single notification past a
  # tight budget. Retrying with a fresh write is what actually proves
  # "the fs-watch path works", as opposed to trusting one observation.
  defp await_fs_watch_write!(jsonl_path, label, attempts \\ 4) do
    handler_id = unique_handler(label)
    ref = make_ref()
    attach_malformed(handler_id, self(), ref)
    do_await_fs_watch_write(jsonl_path, ref, label, attempts)
  end

  defp do_await_fs_watch_write(jsonl_path, ref, label, attempts) when attempts > 0 do
    File.write!(jsonl_path, "#{label}-#{attempts}-not-json\n", [:append])

    receive do
      {:telemetry, ^ref, metadata} -> metadata
    after
      3_000 -> do_await_fs_watch_write(jsonl_path, ref, label, attempts - 1)
    end
  end

  defp do_await_fs_watch_write(_jsonl_path, _ref, _label, 0) do
    flunk("fs-watch never observed a dedicated write after multiple attempts")
  end

  # Polls `fun` (expected to return `nil` until the awaited condition
  # holds) every 10ms until it returns a non-nil value or `timeout_ms`
  # elapses (returning `nil` in that case).
  defp wait_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for(fun, deadline)
        else
          nil
        end

      value ->
        value
    end
  end

  defp valid_bead_line(bead_id) do
    Jason.encode!(%{
      "id" => bead_id,
      "title" => "live tail dispatch #{bead_id}",
      "issue_type" => "task",
      "status" => "open"
    }) <> "\n"
  end

  defp await_dispatch_calls!(expected_count, timeout_ms) do
    wait_for(
      fn ->
        calls = FakeCommandGateway.calls()
        if length(calls) >= expected_count, do: calls
      end,
      timeout_ms
    ) || flunk("expected #{expected_count} dispatch calls from live tail")
  end

  describe "filesystem watch is the primary (<1s) trigger" do
    test "a JSONL write is picked up without waiting for the poll cycle", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-fswatch-#{System.unique_integer([:positive, :monotonic])}"

      # Far outside this test's assert_receive window — if the write
      # is observed at all, it can only be via the fs-watch path, not
      # the poll backstop.
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, poll_ms: 60_000)

      # Proves the fs-watch pipeline (native listener -> FileSystem ->
      # this process' handle_info) is live end-to-end before measuring
      # anything, so the assertion below measures steady-state
      # fs-watch latency, not one-time listener bootstrap latency.
      await_fs_watch_write!(jsonl_path, "warmup")

      handler_id = unique_handler("fswatch-primary")
      ref = make_ref()
      attach_malformed(handler_id, self(), ref)

      File.write!(jsonl_path, "not-json\n", [:append])

      assert_receive {:telemetry, ^ref, metadata}, 3_000
      assert metadata[:project_id] == project_id

      GenServer.stop(pid)
    end

    test "a valid Beads line dispatches from the live fs-watch tail without restart", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-fswatch-dispatch-#{System.unique_integer([:positive, :monotonic])}"
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, poll_ms: 60_000)

      await_fs_watch_write!(jsonl_path, "warmup")
      FakeCommandGateway.reset()

      File.write!(jsonl_path, valid_bead_line("bead-live-fs"), [:append])

      [{create_cmd, 5_000}, {approve_cmd, 5_000}] = await_dispatch_calls!(2, 1_000)
      assert create_cmd.type == "task.create"
      assert create_cmd.payload.external_id == "bead-live-fs"
      assert create_cmd.payload.workflow_type == "generic"
      assert approve_cmd.type == "task.approve"
      assert approve_cmd.payload.task_id == "beads:#{project_id}:bead-live-fs"

      GenServer.stop(pid)
    end

    test "a second write inside the debounce window does not schedule a second timer", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-fswatch-coalesce-#{System.unique_integer([:positive, :monotonic])}"
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, poll_ms: 60_000)

      await_fs_watch_write!(jsonl_path, "warmup")

      File.write!(jsonl_path, "not-json-1\n", [:append])

      first_timer_ref = wait_for(fn -> :sys.get_state(pid).debounce_timer end, 3_000)
      refute is_nil(first_timer_ref), "debounce timer was never scheduled after the first write"

      # Still inside the 100ms debounce window — a second event for
      # the same file must be a no-op, not replace the pending timer
      # with a new one.
      File.write!(jsonl_path, "not-json-2\n", [:append])
      Process.sleep(20)

      assert :sys.get_state(pid).debounce_timer == first_timer_ref

      GenServer.stop(pid)
    end
  end

  describe "poll is the backstop, not the primary trigger (REQ-003, architecture §7.5 risk 3)" do
    test "the default poll_ms is 30_000 when not overridden", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-defaultpoll-#{System.unique_integer([:positive, :monotonic])}"
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, [])

      assert :sys.get_state(pid).poll_ms == 30_000

      GenServer.stop(pid)
    end

    test "poll still catches a write when the fs-watch notification is missed", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-pollback-#{System.unique_integer([:positive, :monotonic])}"

      # Short but not real-production (30_000ms) or real-worst-case
      # (35s) cadence, so the backstop path is provably exercised
      # without a slow test.
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, poll_ms: 200)

      # Simulate a missed fs-watch notification: swap `fs_watcher_pid`
      # for a value that can never match the real watcher's pid in the
      # `handle_info/2` guard, so the (still-running, still-subscribed)
      # real `file_system` events for this write fall through to the
      # catch-all clause and are dropped instead of scheduling a
      # debounced read. Only the poll timer can pick the write up.
      :sys.replace_state(pid, fn state -> %{state | fs_watcher_pid: :simulated_missed_watch} end)

      handler_id = unique_handler("pollback")
      ref = make_ref()
      attach_malformed(handler_id, self(), ref)

      File.write!(jsonl_path, "not-json\n", [:append])

      assert_receive {:telemetry, ^ref, metadata}, 1_000
      assert metadata[:project_id] == project_id

      GenServer.stop(pid)
    end

    test "poll dispatches a valid Beads line when the fs-watch notification is missed", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      project_id = "proj-poll-dispatch-#{System.unique_integer([:positive, :monotonic])}"
      pid = boot_watcher(project_id, tmp_dir, jsonl_path, poll_ms: 200)

      :sys.replace_state(pid, fn state -> %{state | fs_watcher_pid: :simulated_missed_watch} end)
      FakeCommandGateway.reset()

      File.write!(jsonl_path, valid_bead_line("bead-live-poll"), [:append])

      [{create_cmd, 5_000}, {approve_cmd, 5_000}] = await_dispatch_calls!(2, 1_000)
      assert create_cmd.type == "task.create"
      assert create_cmd.payload.external_id == "bead-live-poll"
      assert approve_cmd.type == "task.approve"
      assert approve_cmd.payload.task_id == "beads:#{project_id}:bead-live-poll"

      GenServer.stop(pid)
    end
  end
end
