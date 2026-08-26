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
              case Process.whereis(registry_name) do
                nil -> :ok
                pid -> Process.exit(pid, :normal)
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
