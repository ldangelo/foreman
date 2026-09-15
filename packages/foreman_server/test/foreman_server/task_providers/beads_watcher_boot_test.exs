defmodule ForemanServer.TaskProviders.BeadsWatcherBootTest do
  @moduledoc """
  `init/1`-level tests for `BeadsWatcher` that boot a real supervised
  process (`start_link/1`), as opposed to `beads_watcher_test.exs` and
  `beads_watcher_pipeline_test.exs`, which exercise the pure pipeline
  functions (`process_line/2`, `advance_one_line/2`, `boot_replay/1`)
  against a hand-built state.

  Uses `:set_mox_global` (mirrors `beads_orphan_janitor_test.exs`)
  because `init/1` runs inside the spawned `GenServer` process, not the
  test process, so per-process (`:set_mox_private`) expectations would
  not be visible to it.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TaskProviders.BrRunnerMock

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  defp sync_status_response(coverage_drift, opts \\ []) do
    body = %{
      "coverage_drift" => coverage_drift,
      "coverage" => %{
        "db_exportable_issues" => Keyword.get(opts, :db_exportable_issues, 10),
        "jsonl_unique_ids" => Keyword.get(opts, :jsonl_unique_ids, 7)
      },
      "dirty_count" => Keyword.get(opts, :dirty_count, 0)
    }

    {:ok, %{stdout: Jason.encode!(body), stderr: "", exit_code: 0}}
  end

  defp where_response(jsonl_path) do
    {:ok, %{stdout: Jason.encode!(%{"jsonl_path" => jsonl_path}), stderr: "", exit_code: 0}}
  end

  describe "coverage-drift preflight gate (TRD-009-TEST)" do
    test "refuses to start and logs exact counts when coverage_drift is true", %{
      tmp_dir: tmp_dir
    } do
      expect(BrRunnerMock, :cmd, fn {:sync_status, %{flags: ["--status"]}},
                                    _project_config,
                                    _opts ->
        sync_status_response(true,
          db_exportable_issues: 42,
          jsonl_unique_ids: 37,
          dirty_count: 3
        )
      end)

      handler_id = "coverage-drift-test-#{System.unique_integer([:positive, :monotonic])}"
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :coverage_drift],
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

      Process.flag(:trap_exit, true)

      assert {:error, {:coverage_drift, _status}} =
               BeadsWatcher.start_link(
                 project_id: "proj-drift-#{System.unique_integer([:positive, :monotonic])}",
                 database_path: tmp_dir
               )

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:coverage_drift] == true
      assert metadata[:db_exportable_issues] == 42
      assert metadata[:jsonl_unique_ids] == 37
      assert metadata[:dirty_count] == 3
    end

    test "resumes normally (boots and starts tailing) once coverage_drift is false", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

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

      assert {:ok, pid} =
               BeadsWatcher.start_link(
                 project_id: "proj-nodrift-#{System.unique_integer([:positive, :monotonic])}",
                 database_path: tmp_dir,
                 poll_ms: 60_000
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "boot resilience when CommandRouter is not registered (TRD-2026-d99cd90d regression)" do
    test "does not crash on boot and completes boot_replay once CommandRouter comes up", %{
      tmp_dir: tmp_dir
    } do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      expect(BrRunnerMock, :cmd, fn {:sync_status, %{flags: ["--status"]}},
                                    _project_config,
                                    _opts ->
        sync_status_response(false)
      end)

      expect(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _project_config, _opts
                                    when db_path == tmp_dir ->
        where_response(jsonl_path)
      end)

      app_sup = Process.whereis(ForemanServer.Application)
      assert is_pid(app_sup)

      :ok = Supervisor.terminate_child(app_sup, ForemanServer.CommandRouter)
      assert is_nil(Process.whereis(ForemanServer.CommandRouter))

      on_exit(fn ->
        case Process.whereis(ForemanServer.CommandRouter) do
          nil -> Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
          _pid -> :ok
        end
      end)

      Process.flag(:trap_exit, true)

      # Before the fix, `init/1` ran `boot_replay/1` synchronously and
      # unconditionally, which raised `ArgumentError` the moment
      # `with_beads_lease/2` tried to dispatch through the unregistered
      # `CommandRouter` — crashing this `start_link/1` call outright
      # (`{:ok, pid, {:continue, :boot_replay}}` was never reached).
      assert {:ok, pid} =
               BeadsWatcher.start_link(
                 project_id:
                   "proj-router-defer-#{System.unique_integer([:positive, :monotonic])}",
                 database_path: tmp_dir,
                 poll_ms: 60_000
               )

      assert Process.alive?(pid)
      assert is_nil(:sys.get_state(pid).fs_watcher_pid)

      {:ok, _} = Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)

      fs_watcher_pid =
        wait_until(
          fn ->
            case :sys.get_state(pid).fs_watcher_pid do
              nil -> :retry
              watcher_pid -> {:ok, watcher_pid}
            end
          end,
          "boot_replay to complete once CommandRouter is registered",
          2_000
        )

      assert {:ok, watcher_pid} = fs_watcher_pid
      assert is_pid(watcher_pid)

      GenServer.stop(pid)
    end
  end

  defp wait_until(fun, _label, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_until(fun, deadline)
        else
          :retry
        end

      result ->
        result
    end
  end
end
