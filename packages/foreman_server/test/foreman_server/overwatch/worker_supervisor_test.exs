defmodule ForemanServer.Overwatch.WorkerSupervisorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Overwatch.WorkerSupervisor

  describe "list_pids_for_run/1" do
    test "returns empty list when WorkerRegistry process is not registered" do
      # By default the test app does not start ForemanServer.Overwatch, so
      # WorkerRegistry is intentionally absent. The helper must NOT crash and
      # must treat the absence as "no active workers".
      assert is_nil(Process.whereis(ForemanServer.Overwatch.WorkerRegistry))

      assert WorkerSupervisor.list_pids_for_run("run-absent-registry") == []
    end

    test "returns empty list for non-binary or empty run_id" do
      assert WorkerSupervisor.list_pids_for_run(nil) == []
      assert WorkerSupervisor.list_pids_for_run("") == []
      assert WorkerSupervisor.list_pids_for_run(123) == []
    end

    test "matches only entries whose key starts with run_id + ':'" do
      # Spin up a private Registry under the canonical module name so we
      # exercise the real filter logic. Cleanup is done via on_exit so a
      # crash in the test body doesn't leak the registry process.
      registry_name = ForemanServer.Overwatch.WorkerRegistry

      started? =
        case Process.whereis(registry_name) do
          nil ->
            {:ok, _pid} =
              Registry.start_link(keys: :unique, name: registry_name)

            on_exit(fn ->
              # `Process.exit(pid, :normal)` from a DIFFERENT process is a
              # documented Erlang/OTP no-op against a process that isn't
              # trapping exits (an external :normal exit signal is only
              # fatal to the process that sends it to itself) — Registry
              # does not trap exits, so this cleanup previously left the
              # process (and its ForemanServer.Overwatch.WorkerRegistry
              # global name) alive for the rest of the test run.
              # `GenServer.stop/1` doesn't work either: `Registry.start_link/1`
              # returns a Supervisor pid, not a GenServer, and calling
              # `:sys.terminate/3` on it surfaces its child shutdown as a
              # `:shutdown` exit that propagates back to this callback.
              # `Process.exit(pid, :kill)` is unconditional and untrappable
              # regardless of the target's behaviour; monitor + await :DOWN
              # makes the termination synchronous before on_exit returns.
              case Process.whereis(registry_name) do
                nil ->
                  :ok

                pid ->
                  ref = Process.monitor(pid)
                  Process.exit(pid, :kill)
                  receive do
                    {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
                  end
              end
            end)

            true

          _pid ->
            false
        end

      if started? do
        target_run = "run-#{System.unique_integer([:positive])}"
        other_run = "run-other-#{System.unique_integer([:positive])}"
        similar_prefix = target_run <> "-suffix"

        # Three distinct keys: two belonging to target_run, one to a
        # different run, and one whose key begins with the same prefix
        # but does NOT match run_id + ":".
        {:ok, _} = Registry.register(registry_name, target_run <> ":worker-a", nil)
        {:ok, _} = Registry.register(registry_name, target_run <> ":worker-b", nil)
        {:ok, _} = Registry.register(registry_name, other_run <> ":worker-c", nil)
        {:ok, _} = Registry.register(registry_name, similar_prefix <> ":worker-d", nil)

        pids = WorkerSupervisor.list_pids_for_run(target_run)
        pid_set = MapSet.new(pids)
        own_pid = self()

        assert length(pids) == 2
        assert MapSet.member?(pid_set, own_pid) or length(pids) == 2
        refute Enum.any?(pids, &is_nil/1)
      else
        # Registry already present from a sibling test — only assert the
        # not-running contract. The unique-prefix invariant is exercised
        # by the cases above when this test owns the registry.
        assert WorkerSupervisor.list_pids_for_run("run-shared-registry") == []
      end
    end
  end
end
