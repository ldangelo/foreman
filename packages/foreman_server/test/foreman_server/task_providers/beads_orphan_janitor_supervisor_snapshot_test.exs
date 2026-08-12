defmodule ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisorSnapshotTest do
  @moduledoc """
  TRD-013a-TASK scenarios: `BeadsOrphanJanitorSupervisor.snapshot/1` read path.

  Doctor reads cached janitor counters via the supervisor's public
  `snapshot/1` API rather than calling `BeadsOrphanJanitor.run_scan/2`
  directly. These tests cover the contract documented at
  `snapshot/1`:

    * `{:error, :not_running}` when the supervisor process is gone
      (the `Process.whereis` guard) or when no janitor is registered
      for the requested project_id (the `Registry.lookup` fallback);
    * `{:ok, nil}` when a janitor is running but no scan has cached
      counters yet;
    * `{:ok, %Counters{}}` once the janitor has populated
      `state.last_counters`.

  The supervisor hardcodes `__MODULE__` as its registered name, so the
  lifecycle setup here mirrors production: start under the module
  name, exercise children, terminate children on exit, stop the
  supervisor itself in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsOrphanJanitor
  alias ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor
  alias ForemanServer.TaskProviders.BrRunnerMock

  setup_all do
    {:ok, _mox} = Application.ensure_all_started(:mox)
    {:ok, _telemetry} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Make sure the supervisor isn't already up from a prior module that
    # may have started it; we always start it ourselves under __MODULE__.
    case Process.whereis(BeadsOrphanJanitorSupervisor) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        :ok
    end

    {:ok, sup} = BeadsOrphanJanitorSupervisor.start_link()

    on_exit(fn ->
      # Each test owns its own janitor children; the parent setup's
      # on_exit only needs to stop the supervisor — children die with it.
      if Process.alive?(sup) do
        try do
          GenServer.stop(sup, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Stub br --where so janitor init resolves the JSONL path; every child
    # the supervisor starts uses the same stub.
    stub(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _config, _opts ->
      jsonl_path = db_path <> ".jsonl"
      File.write!(jsonl_path, "")
      stdout = ~s({"jsonl_path":"#{jsonl_path}"})
      {:ok, %{stdout: stdout}}
    end)

    :ok
  end

  describe "snapshot/1 — read-path contract" do
    test "returns {:error, :not_running} when no child is registered for project_id" do
      assert {:error, :not_running} =
               BeadsOrphanJanitorSupervisor.snapshot("no-such-project")
    end

    test "returns {:ok, nil} when a janitor is running but no scan has completed" do
      project_id = "snapshot-running-#{System.unique_integer([:positive])}"
      database_path = Path.join(System.tmp_dir!(), "snap-#{project_id}")
      jsonl_path = database_path <> ".jsonl"

      {:ok, _child_pid} =
        BeadsOrphanJanitorSupervisor.start_child(project_id, database_path)

      on_exit(fn -> File.rm(jsonl_path) end)

      assert is_pid(BeadsOrphanJanitorSupervisor.lookup(project_id))
      assert {:ok, nil} = BeadsOrphanJanitorSupervisor.snapshot(project_id)
    end

    test "returns {:ok, counters} after janitor state.last_counters has been populated" do
      project_id = "snapshot-after-scan-#{System.unique_integer([:positive])}"
      database_path = Path.join(System.tmp_dir!(), "snap-#{project_id}")
      jsonl_path = database_path <> ".jsonl"

      {:ok, child_pid} =
        BeadsOrphanJanitorSupervisor.start_child(project_id, database_path)

      on_exit(fn -> File.rm(jsonl_path) end)

      now_ms = System.system_time(:millisecond)

      :sys.replace_state(child_pid, fn s ->
        %{s | last_counters: BeadsOrphanJanitor.run_scan(s, now_ms: now_ms)}
      end)

      assert {:ok, %BeadsOrphanJanitor.Counters{}} =
               BeadsOrphanJanitorSupervisor.snapshot(project_id)
    end
  end
end
