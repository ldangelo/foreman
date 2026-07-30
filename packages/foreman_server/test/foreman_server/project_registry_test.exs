defmodule ForemanServer.ProjectRegistryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectRegistry, ProjectSupervisor, Project}

  setup do
    # Ensure clean registry state per test
    on_exit(fn ->
      Registry.lookup(:project_registry, "test-project")
      |> Enum.each(fn {pid, _} -> send(pid, {:project_registry, :unregistered}) end)

      ProjectRegistry.unregister("test-project")
      ProjectRegistry.unregister("test-project-2")
      ProjectRegistry.unregister("test-project-3")
    end)

    :ok
  end

  describe "via/1" do
    test "returns a via tuple for Registry" do
      assert ProjectRegistry.via("proj-1") ==
               {:via, Registry, {:project_registry, "proj-1"}}
    end

    test "accepts binary project_id" do
      assert {:via, Registry, {:project_registry, "any-id"}} =
               ProjectRegistry.via("any-id")
    end
  end

  describe "register/2" do
    test "registers self with the given project_id" do
      assert ProjectRegistry.register("test-project", self()) == :ok
      assert ProjectRegistry.lookup("test-project") == {:ok, self()}
    end

    test "returns error when project_id is already registered" do
      ProjectRegistry.register("test-project", self())
      assert ProjectRegistry.lookup("test-project") == {:ok, self()}

      assert ProjectRegistry.register("test-project", self()) ==
               {:error, :already_registered}
    end

    test "returns error when pid is not self" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert ProjectRegistry.register("test-project", pid) == {:error, :not_self}
      send(pid, :stop)
    end

    test "requires binary project_id" do
      assert_raise(FunctionClauseError, fn ->
        ProjectRegistry.register(123, self())
      end)
    end

    test "spawned process registers itself and Registry auto-cleans on death" do
      parent = self()

      pid =
        spawn(fn ->
          ProjectRegistry.register("test-project-2", self())
          send(parent, {:registered, self()})

          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(pid)
      assert_receive {:registered, ^pid}
      assert {:ok, ^pid} = ProjectRegistry.lookup("test-project-2")

      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # Registry cleanup is async — poll until entry disappears
      retries = 20

      result =
        Enum.reduce_while(1..retries, :error, fn i, _ ->
          case ProjectRegistry.lookup("test-project-2") do
            :error ->
              {:halt, :error}

            {:ok, ^pid} when i < retries ->
              Process.sleep(5)
              {:cont, :error}

            {:ok, ^pid} ->
              {:halt, {:error, {:still_registered, i, retries}}}
          end
        end)

      assert result == :error
    end
  end

  describe "unregister/1" do
    test "removes a registered project_id" do
      ProjectRegistry.register("test-project", self())
      assert ProjectRegistry.lookup("test-project") == {:ok, self()}

      ProjectRegistry.unregister("test-project")
      assert ProjectRegistry.lookup("test-project") == :error
    end

    test "is idempotent" do
      ProjectRegistry.unregister("nonexistent")
      ProjectRegistry.unregister("nonexistent")
    end

    test "requires binary project_id" do
      assert_raise(FunctionClauseError, fn ->
        ProjectRegistry.unregister(123)
      end)
    end
  end

  describe "lookup/1" do
    test "returns :error for unregistered project_id" do
      assert ProjectRegistry.lookup("nonexistent") == :error
    end

    test "returns {:ok, pid} for registered project_id" do
      ProjectRegistry.register("test-project", self())
      assert ProjectRegistry.lookup("test-project") == {:ok, self()}
    end

    test "requires binary project_id" do
      assert_raise(FunctionClauseError, fn ->
        ProjectRegistry.lookup(123)
      end)
    end
  end

  describe "active_project_ids/0" do
    test "returns a list of active project ids" do
      assert is_list(ProjectRegistry.active_project_ids())
    end

    test "via-registered ProjectSupervisor appears in active_project_ids" do
      project = %Project{id: "via-active-test", path: "/tmp/test"}
      pid = start_supervised!({ProjectSupervisor, project})
      assert is_pid(pid)
      assert "via-active-test" in ProjectRegistry.active_project_ids()
    end

    test "direct register appears in active_project_ids and disappears after unregister" do
      myself = self()

      try do
        assert "direct-reg-test" not in ProjectRegistry.active_project_ids()
        assert :ok = ProjectRegistry.register("direct-reg-test", myself)
        assert "direct-reg-test" in ProjectRegistry.active_project_ids()
        ProjectRegistry.unregister("direct-reg-test")
        refute "direct-reg-test" in ProjectRegistry.active_project_ids()
      after
        ProjectRegistry.unregister("direct-reg-test")
      end
    end

    test "via-registered process disappears from active_project_ids on normal exit" do
      project = %Project{id: "exit-test", path: "/tmp/test"}
      {:ok, pid} = ProjectSupervisor.start_link(project)

      assert "exit-test" in ProjectRegistry.active_project_ids()
      GenServer.stop(pid, :normal)

      # Registry cleanup is async — poll until entry disappears
      retries = 20

      result =
        Enum.reduce_while(1..retries, :error, fn i, _ ->
          if "exit-test" in ProjectRegistry.active_project_ids() do
            if i < retries,
              do:
                (
                  Process.sleep(5)
                  {:cont, :error}
                ),
              else: {:halt, {:error, {:still_present, retries}}}
          else
            {:halt, :ok}
          end
        end)

      assert result == :ok
    end
  end

  describe "integration: via/1 with ProjectSupervisor" do
    test "ProjectSupervisor started with via is reachable via ProjectRegistry.lookup" do
      project = %Project{id: "via-test-project", path: "/tmp/test"}
      _supervisor_pid = start_supervised!({ProjectSupervisor, project})

      # ProjectRegistry.lookup returns the ProjectWorker pid (registered via :via),
      # not the supervisor pid returned by start_supervised!/DynamicSupervisor.
      assert {:ok, worker_pid} = ProjectRegistry.lookup("via-test-project")
      assert ProjectSupervisor.project("via-test-project") == project
      assert is_pid(worker_pid)
    end
  end

  describe "TRD-003: start_project/1 idempotency and restart" do
    test "start_project/1 called twice returns the same worker pid" do
      project = %Project{id: "trd-003-ps-idem-#{:rand.uniform(65_535)}", path: "/tmp/test"}

      {:ok, pid1} = ProjectSupervisor.start_project(project)
      on_exit(fn -> cleanup_project(project.id) end)

      {:ok, pid2} = ProjectSupervisor.start_project(project)
      assert pid1 == pid2
    end

    test "start_project/1 concurrent calls all return the same worker pid" do
      project = %Project{id: "trd-003-concurrent-#{:rand.uniform(65_535)}", path: "/tmp/test"}
      on_exit(fn -> cleanup_project(project.id) end)

      caller_results =
        Enum.map(1..10, fn _ ->
          caller = self()
          spawn_link(fn -> send(caller, ProjectSupervisor.start_project(project)) end)
        end)
        |> Enum.map(fn _ ->
          receive do
            result -> result
          after
            5_000 -> raise("timeout waiting for concurrent start_project result")
          end
        end)

      pids = Enum.map(caller_results, &elem(&1, 1))
      assert Enum.all?(caller_results, &match?({:ok, _}, &1))
      assert Enum.uniq(pids) |> length() == 1
    end

    test "start_project/1 rejects inactive project" do
      project = %Project{
        id: "trd-003-inactive-#{:rand.uniform(65_535)}",
        path: "/tmp/test",
        status: :inactive
      }

      assert {:error, :inactive_project} = ProjectSupervisor.start_project(project)
    end

    test "ensure_project/1 called twice returns the same worker pid" do
      project = %Project{id: "trd-003-reg-idem-#{:rand.uniform(65_535)}", path: "/tmp/test"}

      {:ok, pid1} = ProjectRegistry.ensure_project(project)
      on_exit(fn -> cleanup_project(project.id) end)

      {:ok, pid2} = ProjectRegistry.ensure_project(project)
      assert pid1 == pid2
    end

    test "worker re-registers under same key after :kill restart" do
      project = %Project{id: "trd-003-restart-#{:rand.uniform(65_535)}", path: "/tmp/test"}

      {:ok, pid1} = ProjectRegistry.ensure_project(project)
      on_exit(fn -> cleanup_project(project.id) end)

      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      {:ok, pid2} = wait_for_different_pid(project.id, pid1)
      assert pid2 != pid1
    end

    test "start_project/1 never returns a dead pid from stale registry entry" do
      project = %Project{id: "trd-003-stale-#{:rand.uniform(65_535)}", path: "/tmp/test"}

      {:ok, pid1} = ProjectSupervisor.start_project(project)
      on_exit(fn -> cleanup_project(project.id) end)

      # Confirm pid1 is dead before calling start_project again.
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}
      refute Process.alive?(pid1)

      # start_project must not return the dead pid (even if registry cleanup was async).
      {:ok, pid2} = ProjectSupervisor.start_project(project)
      assert Process.alive?(pid2)
      assert {:ok, ^pid2} = ProjectRegistry.lookup(project.id)
    end
  end

  # Finds the ProjectSupervisor managing `project_id` via DynamicSupervisor.which_children
  # (returns supervisor pids), then Supervisor.which_children on each to find the
  # ProjectWorker pid, and terminates the supervisor — cleaning up the whole tree.
  defp cleanup_project(project_id) do
    sup_pid = ForemanServer.ProjectDynamicSupervisor

    supervisor_pid =
      Enum.find_value(DynamicSupervisor.which_children(sup_pid), fn
        {_id, child_sup_pid, :supervisor, [ForemanServer.ProjectSupervisor]}
        when is_pid(child_sup_pid) ->
          workers =
            try do
              Supervisor.which_children(child_sup_pid)
            catch
              :exit, _ -> nil
            end

          matching_worker? =
            workers != nil and
              Enum.any?(workers, fn
                {_id, worker_pid, :worker, [ForemanServer.ProjectWorker]}
                when is_pid(worker_pid) ->
                  case Registry.lookup(:project_registry, project_id) do
                    [{^worker_pid, _}] -> true
                    _ -> false
                  end

                _ ->
                  false
              end)

          if matching_worker?, do: child_sup_pid

        _ ->
          nil
      end)

    if supervisor_pid do
      try do
        DynamicSupervisor.terminate_child(sup_pid, supervisor_pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # Waits until the registry returns a pid different from `old_pid`.
  defp wait_for_different_pid(project_id, old_pid, retries \\ 50)

  defp wait_for_different_pid(_project_id, _old_pid, 0), do: :error

  defp wait_for_different_pid(project_id, old_pid, retries) do
    case ProjectRegistry.lookup(project_id) do
      {:ok, ^old_pid} ->
        Process.sleep(10)
        wait_for_different_pid(project_id, old_pid, retries - 1)

      {:ok, pid} when pid != old_pid ->
        {:ok, pid}

      :error ->
        Process.sleep(10)
        wait_for_different_pid(project_id, old_pid, retries - 1)
    end
  end
end
