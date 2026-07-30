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
            :error -> {:halt, :error}
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
            if i < retries, do: (Process.sleep(5); {:cont, :error}), else: {:halt, {:error, {:still_present, retries}}}
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

      pid = start_supervised!({ProjectSupervisor, project})

      assert ProjectRegistry.lookup("via-test-project") == {:ok, pid}
      assert ProjectSupervisor.project("via-test-project") == project
    end
  end
end
