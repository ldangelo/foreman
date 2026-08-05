defmodule ForemanServer.ProjectRegistrySupervisorStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{
    ProjectRegistry,
    ProjectStore,
    ProjectionStore,
    ProjectSupervisor
  }

  defp unique_id(prefix),
    do: "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

  setup_all do
    # ProjectRegistry is not in the application supervision tree; manual start.
    case ProjectRegistry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "ProjectRegistry — direct API contracts" do
    test "via/1 returns a via tuple referencing the registry" do
      assert {:via, Registry, {:project_registry, "x"}} = ProjectRegistry.via("x")
    end
  end

  describe "ProjectStore.save/1 + read paths (CommandRouter in-memory)" do
    test "save/1 issues a project.register command" do
      project_id = unique_id("store")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "demo", path: "/tmp/demo"})
      assert ProjectionStore.project_projection(project_id).name == "demo"
    end

    test "save/1 again with same project_id issues a project.update" do
      project_id = unique_id("store2")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "v1", path: "/tmp/v1"})
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "v2", path: "/tmp/v2"})
      assert ProjectionStore.project_projection(project_id).name == "v2"
    end

    test "list/0 returns all projects" do
      project_id = unique_id("store3")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "x", path: "/tmp/x"})
      ids = ProjectStore.list() |> Enum.map(& &1.project_id)
      assert project_id in ids
    end

    test "get/1 returns a single project" do
      project_id = unique_id("store4")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "y", path: "/tmp/y"})
      assert %{project_id: ^project_id} = ProjectStore.get(project_id)
    end

    test "archive/1 archives the project" do
      project_id = unique_id("store5")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "z", path: "/tmp/z"})
      {:ok, _} = ProjectStore.archive(project_id)
      assert ProjectionStore.project_projection(project_id).status == "archived"
    end

    test "reactivate/1 reactivates an archived project" do
      project_id = unique_id("store6")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "w", path: "/tmp/w"})
      {:ok, _} = ProjectStore.archive(project_id)
      {:ok, _} = ProjectStore.reactivate(project_id)
      assert ProjectionStore.project_projection(project_id).status == "active"
    end

    test "save/1 with missing project_id returns an error" do
      assert {:error, _} = ProjectStore.save(%{name: "no-id"})
    end

    test "get/1 for unknown project returns nil" do
      assert ProjectStore.get(unique_id("missing")) == nil
    end

    test "save/1 updates the projection after multiple saves" do
      project_id = unique_id("store7")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "a", path: "/tmp/a"})
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "b", path: "/tmp/b"})
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "c", path: "/tmp/c"})
      assert ProjectionStore.project_projection(project_id).name == "c"
    end

    test "save/1 with default_branch in payload persists branch" do
      project_id = unique_id("store8")

      {:ok, _} =
        ProjectStore.save(%{project_id: project_id, path: "/tmp/p", default_branch: "develop"})

      assert ProjectionStore.project_projection(project_id).default_branch == "develop"
    end
  end

  describe "ProjectSupervisor crash → restart" do
    test "killed project process is restarted by Aggregator" do
      project_id = unique_id("crash")
      {:ok, pid1} = ProjectSupervisor.start_project(project_id)
      # Actor is registered under the AggregateRegistry keyed by aggregate_id.
      assert [{^pid1, _}] = Registry.lookup(ForemanServer.AggregateRegistry, project_id)
      assert Process.alive?(pid1)

      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      # Aggregator restarts the actor under the same name. The supervisor
      # restart is async — poll until a *live* pid different from pid1 appears.
      # The registry briefly holds the dead pid between DOWN and the restart,
      # so accepting the first entry races the supervisor.
      pid2 = wait_for_live_restart(project_id, pid1, 1_000)

      assert is_pid(pid2)
      assert pid2 != pid1
      assert Process.alive?(pid2)
    end

    defp wait_for_live_restart(project_id, dead_pid, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_for_live_restart(project_id, dead_pid, deadline)
    end

    defp do_wait_for_live_restart(project_id, dead_pid, deadline) do
      case live_pid_other_than(dead_pid, project_id) do
        nil ->
          if System.monotonic_time(:millisecond) >= deadline do
            nil
          else
            Process.sleep(10)
            do_wait_for_live_restart(project_id, dead_pid, deadline)
          end

        pid ->
          pid
      end
    end

    defp live_pid_other_than(pid, project_id) do
      case Registry.lookup(ForemanServer.AggregateRegistry, project_id) do
        [{candidate, _}] when candidate != pid ->
          if Process.alive?(candidate), do: candidate, else: nil

        _ ->
          nil
      end
    end
  end
end
