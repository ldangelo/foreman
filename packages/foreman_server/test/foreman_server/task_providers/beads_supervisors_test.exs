defmodule ForemanServer.TaskProviders.BeadsSupervisorsTest do
  @moduledoc """
  TRD-014-TASK scenarios: supervisor flag-gated supervision.

  Verifies that:
    * `:start_beads_watcher?` false → `BeadsWatcherSupervisor` is NOT started
    * `:start_beads_watcher?` true  → `BeadsWatcherSupervisor` is started and
                                       spawns a child per registered project
    * `:start_beads_orphan_janitor?` false → not started
    * `:start_beads_orphan_janitor?` true  → started and spawns children

  Flag gating is verified two ways:
    1. Direct unit test of `ForemanServer.Application.maybe_*_child/0` — the
       child-spec builder used by `Application.start/2`. This proves the flag
       value alone determines whether the supervisor appears in the boot
       children list, without restarting the running app.
    2. Lifecycle test that starts each supervisor under its default module
       name (so `start_child/2`, `which_children/0`, and `lookup/1` resolve
       via `Process.whereis(__MODULE__)` exactly as in production) and
       exercises add/remove/idempotency paths.

  Note: `DynamicSupervisor.terminate_child/2` is asynchronous — it returns
  once the supervisor has *signalled* the child to exit, not after the
  child's Registry entry has been cleaned up. Lifecycle assertions that
  read `which_children/0` or `lookup/1` immediately after a stop call go
  through the bounded `await_*` helpers below, which tolerate that race.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.Application, as: ForemanApp
  alias ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor
  alias ForemanServer.TaskProviders.BeadsWatcherSupervisor
  alias ForemanServer.TaskProviders.BrRunnerMock

  setup_all do
    {:ok, _mox} = Application.ensure_all_started(:mox)
    {:ok, _telemetry} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original_watcher = Application.get_env(:foreman_server, :start_beads_watcher?, false)
    original_janitor = Application.get_env(:foreman_server, :start_beads_orphan_janitor?, false)

    Application.put_env(:foreman_server, :start_beads_watcher?, false)
    Application.put_env(:foreman_server, :start_beads_orphan_janitor?, false)

    # Create one fresh tmp dir for the test and confine every jsonl file
    # the stub writes under it; on_exit removes the whole dir atomically.
    tmp_root =
      Path.join(System.tmp_dir!(), "beads_supervisors_test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)

    stub(BrRunnerMock, :cmd, fn {:where, config}, _project_config, _opts ->
      # Every jsonl the supervisor's children observe must live under
      # tmp_root so on_exit's File.rm_rf!/1 cleans up unconditionally.
      # Use the caller-supplied database_path basename (strips any absolute
      # prefix or directory injection) and place it inside tmp_root.
      caller_db =
        case Map.get(config, :database_path) do
          nil -> nil
          path when is_binary(path) -> Path.basename(path)
        end

      basename =
        caller_db || "unknown-#{System.unique_integer([:positive])}.db"

      jsonl_path = Path.join(tmp_root, basename <> ".jsonl")
      File.write!(jsonl_path, "")
      stdout = ~s({"jsonl_path":"#{jsonl_path}"})
      {:ok, %{stdout: stdout}}
    end)

    on_exit(fn ->
      Application.put_env(:foreman_server, :start_beads_watcher?, original_watcher)
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, original_janitor)
      File.rm_rf!(tmp_root)
    end)

    :ok
  end

  # --- Child-spec builder: scenarios 1-4 -------------------------------

  describe "ForemanServer.Application child-spec builder" do
    test "scenario 1: maybe_beads_watcher_child/0 returns [] when flag is false" do
      Application.put_env(:foreman_server, :start_beads_watcher?, false)
      assert ForemanApp.maybe_beads_watcher_child() == []
      assert is_nil(Process.whereis(BeadsWatcherSupervisor))
    end

    test "scenario 2: maybe_beads_watcher_child/0 returns [supervisor] when flag is true" do
      Application.put_env(:foreman_server, :start_beads_watcher?, true)
      assert ForemanApp.maybe_beads_watcher_child() == [BeadsWatcherSupervisor]
    end

    test "scenario 3: maybe_beads_orphan_janitor_child/0 returns [] when flag is false" do
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, false)
      assert ForemanApp.maybe_beads_orphan_janitor_child() == []
      assert is_nil(Process.whereis(BeadsOrphanJanitorSupervisor))
    end

    test "scenario 4: maybe_beads_orphan_janitor_child/0 returns [supervisor] when flag is true" do
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, true)
      assert ForemanApp.maybe_beads_orphan_janitor_child() == [BeadsOrphanJanitorSupervisor]
    end

    test "flags are independent — toggling one does not flip the other" do
      Application.put_env(:foreman_server, :start_beads_watcher?, true)
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, false)

      assert ForemanApp.maybe_beads_watcher_child() == [BeadsWatcherSupervisor]
      assert ForemanApp.maybe_beads_orphan_janitor_child() == []
    end
  end

  # --- Supervisor lifecycle under default module name -------------------

  describe "BeadsWatcherSupervisor lifecycle (default module name)" do
    setup do
      {:ok, sup} = BeadsWatcherSupervisor.start_link()
      on_exit(fn -> safe_stop(sup) end)
      :ok
    end

    test "spawns one child per registered project and tears it down on unregister" do
      assert [] = BeadsWatcherSupervisor.which_children()

      {:ok, started_pid} =
        BeadsWatcherSupervisor.start_child("project-watcher-1", "/tmp/project-watcher-1.db")

      assert [{"project-watcher-1", ^started_pid}] = BeadsWatcherSupervisor.which_children()
      assert is_pid(started_pid)
      assert ^started_pid = BeadsWatcherSupervisor.lookup("project-watcher-1")

      :ok = BeadsWatcherSupervisor.stop_child("project-watcher-1")
      await_no_child(BeadsWatcherSupervisor, "project-watcher-1")

      # Idempotent stop.
      assert :ok = BeadsWatcherSupervisor.stop_child("project-watcher-1")
      assert :ok = BeadsWatcherSupervisor.stop_child("never-registered")
    end
  end

  describe "BeadsOrphanJanitorSupervisor lifecycle (default module name)" do
    setup do
      {:ok, sup} = BeadsOrphanJanitorSupervisor.start_link()
      on_exit(fn -> safe_stop(sup) end)
      :ok
    end

    test "spawns children per project; tearing one down leaves the other" do
      assert [] = BeadsOrphanJanitorSupervisor.which_children()

      {:ok, _pid1} =
        BeadsOrphanJanitorSupervisor.start_child(
          "project-janitor-1",
          "/tmp/project-janitor-1.db"
        )

      {:ok, _pid2} =
        BeadsOrphanJanitorSupervisor.start_child(
          "project-janitor-2",
          "/tmp/project-janitor-2.db"
        )

      janitor_children = BeadsOrphanJanitorSupervisor.which_children()
      assert Enum.any?(janitor_children, &match?({"project-janitor-1", _pid}, &1))
      assert Enum.any?(janitor_children, &match?({"project-janitor-2", _pid}, &1))

      :ok = BeadsOrphanJanitorSupervisor.stop_child("project-janitor-1")
      await_pid_nil(BeadsOrphanJanitorSupervisor, "project-janitor-1")

      remaining = BeadsOrphanJanitorSupervisor.which_children()
      refute Enum.any?(remaining, &match?({"project-janitor-1", _pid}, &1))
      assert Enum.any?(remaining, &match?({"project-janitor-2", _pid}, &1))

      # Idempotent stop.
      assert :ok = BeadsOrphanJanitorSupervisor.stop_child("project-janitor-1")
      assert :ok = BeadsOrphanJanitorSupervisor.stop_child("never-registered")
    end
  end

  # --- Flag-gated Projector behavior ------------------------------------

  describe "Projector gating (flag-driven spawn/stop)" do
    alias ForemanServer.TaskProvider.ProjectProviderProjector

    test "spawn is a no-op when supervisor flags are false (no :noproc raises)" do
      Application.put_env(:foreman_server, :start_beads_watcher?, false)
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, false)

      assert is_nil(Process.whereis(BeadsWatcherSupervisor))
      assert is_nil(Process.whereis(BeadsOrphanJanitorSupervisor))

      task_provider = %{
        provider: :configured_provider,
        config: %{"database_path" => "/tmp/project-gated.db"}
      }

      payload = %{
        event_type: "ProjectRegistered",
        payload: %{
          project_id: "project-gated",
          path: "/tmp/project-gated",
          task_provider: task_provider
        }
      }

      assert :ok = ProjectProviderProjector.process_event(payload)
    end

    test "stop is a no-op when supervisor flags are false" do
      Application.put_env(:foreman_server, :start_beads_watcher?, false)
      Application.put_env(:foreman_server, :start_beads_orphan_janitor?, false)

      payload = %{
        event_type: "ProjectRegistered",
        payload: %{
          project_id: "project-stop-only",
          path: "/tmp/project-stop-only",
          task_provider: %{
            provider: :switched_provider,
            config: %{"database_path" => "/tmp/project-stop-only.db"}
          }
        }
      }

      assert :ok = ProjectProviderProjector.process_event(payload)
    end
  end

  # --- helpers ----------------------------------------------------------

  defp await_no_child(supervisor, project_id) do
    do_await(fn ->
      children = supervisor.which_children()
      refute Enum.any?(children, &match?({^project_id, _pid}, &1))
    end)
  end

  defp await_pid_nil(supervisor, project_id) do
    do_await(fn -> assert supervisor.lookup(project_id) == nil end)
  end

  # `terminate_child/2` returns once the supervisor has signalled the child,
  # not after Registry cleanup. The child's terminate callback owns the
  # Registry removal; until it runs the supervisor still reports the child
  # via `which_children/0` and `lookup/1`. Retry briefly to absorb that.
  defp do_await(fun) do
    try do
      fun.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(20)
        fun.()
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
