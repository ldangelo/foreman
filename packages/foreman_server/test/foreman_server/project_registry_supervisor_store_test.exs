defmodule ForemanServer.ProjectRegistrySupervisorStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{
    EventStore,
    ProjectRegistry,
    ProjectStore,
    ProjectionStore,
    ProjectSupervisor
  }

  @poll_timeout_ms 1_000

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
      assert wait_for_project_projection(project_id).name == "demo"
    end

    test "save/1 again with same project_id issues a project.update" do
      project_id = unique_id("store2")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "v1", path: "/tmp/v1"})
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "v2", path: "/tmp/v2"})
      assert ProjectStore.get(project_id).name == "v2"
    end

    test "save/1 preserves recorded registered_at and advances version across router read-back" do
      project_id = unique_id("store-version")
      stream_id = "project:#{project_id}"

      {:ok, _} =
        ProjectStore.save(%{project_id: project_id, name: "v1", path: "/tmp/store-version-v1"})

      {:ok, [registered_event]} = EventStore.read_stream_forward(stream_id, 0, 99_999)
      expected_registered_at = DateTime.to_iso8601(registered_event.created_at)

      registered =
        poll_until(
          fn ->
            projection = wait_for_project_projection(project_id)

            if projection.version == registered_event.stream_version and
                 projection.registered == expected_registered_at and
                 projection.registered_at == expected_registered_at do
              {:ok, projection}
            else
              {:error, projection}
            end
          end,
          "registered project metadata #{project_id}"
        )

      assert registered.version == registered_event.stream_version
      assert registered.registered == expected_registered_at
      assert registered.registered_at == expected_registered_at

      {:ok, _} =
        ProjectStore.save(%{project_id: project_id, name: "v2", path: "/tmp/store-version-v2"})

      {:ok, recorded_events} = EventStore.read_stream_forward(stream_id, 0, 99_999)
      last_recorded = List.last(recorded_events)

      updated =
        poll_until(
          fn ->
            projection = wait_for_project_projection(project_id)

            if projection.name == "v2" and projection.version == last_recorded.stream_version and
                 projection.registered == expected_registered_at and
                 projection.registered_at == expected_registered_at do
              {:ok, projection}
            else
              {:error, projection}
            end
          end,
          "updated project metadata #{project_id}"
        )

      assert updated.name == "v2"
      assert updated.version == last_recorded.stream_version
      assert updated.registered == expected_registered_at
      assert updated.registered_at == expected_registered_at
    end

    test "post-commit recovery preserves projection order without duplicating committed events" do
      project_id = unique_id("store-post-commit-fail")
      stream_id = "project:#{project_id}"
      test_pid = self()
      :ok = ProjectionStore.subscribe()

      with_post_commit_readback_hook(
        fn
          ^stream_id, 0, [_event_data] ->
            send(test_pid, :post_commit_readback_attempt)
            {:error, :forced_post_commit_read_failure}

          _, _, _ ->
            :ok
        end,
        [25, 100],
        fn ->
          assert {:ok, %{"event_type" => "ProjectRegistered"}} =
                   ProjectStore.save(%{
                     project_id: project_id,
                     name: "v1",
                     path: "/tmp/store-post-commit-fail-v1"
                   })

          assert_receive :post_commit_readback_attempt, @poll_timeout_ms
          assert ProjectStore.get(project_id).name == "v1"

          assert {:ok, %{"event_type" => "ProjectUpdated"}} =
                   ProjectStore.save(%{
                     project_id: project_id,
                     name: "v2",
                     path: "/tmp/store-post-commit-fail-v2"
                   })

          {:ok, events} = EventStore.read_stream_forward(stream_id, 0, 99_999)
          assert Enum.map(events, & &1.event_type) == ["ProjectRegistered", "ProjectUpdated"]

          assert receive_project_projection_event(project_id).event_type ==
                   "ProjectRegistered"

          assert receive_project_projection_event(project_id).event_type == "ProjectUpdated"

          projection = ProjectStore.get(project_id)
          assert projection.name == "v2"
          assert projection.version == 2
        end
      )
    end

    test "list/0 returns all projects" do
      project_id = unique_id("store3")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "x", path: "/tmp/x"})

      ids =
        poll_until(
          fn ->
            ids = ProjectStore.list() |> Enum.map(& &1.project_id)
            if project_id in ids, do: {:ok, ids}, else: {:error, ids}
          end,
          "project list containing #{project_id}"
        )

      assert project_id in ids
    end

    test "get/1 returns a single project" do
      project_id = unique_id("store4")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "y", path: "/tmp/y"})
      assert %{project_id: ^project_id} = wait_for_project(project_id)
    end

    test "archive/1 archives the project" do
      project_id = unique_id("store5")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "z", path: "/tmp/z"})
      wait_for_project_projection(project_id)
      {:ok, _} = ProjectStore.archive(project_id)

      assert poll_until_project_status(project_id, "archived").status == "archived"
    end

    test "reactivate/1 reactivates an archived project" do
      project_id = unique_id("store6")
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "w", path: "/tmp/w"})
      wait_for_project_projection(project_id)
      {:ok, _} = ProjectStore.archive(project_id)
      assert poll_until_project_status(project_id, "archived").status == "archived"
      {:ok, _} = ProjectStore.reactivate(project_id)

      assert poll_until_project_status(project_id, "active").status == "active"
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
      assert wait_for_project_name(project_id, "a").name == "a"
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "b", path: "/tmp/b"})
      assert wait_for_project_name(project_id, "b").name == "b"
      {:ok, _} = ProjectStore.save(%{project_id: project_id, name: "c", path: "/tmp/c"})
      assert wait_for_project_name(project_id, "c").name == "c"
    end

    test "save/1 with default_branch in payload persists branch" do
      project_id = unique_id("store8")

      {:ok, _} =
        ProjectStore.save(%{project_id: project_id, path: "/tmp/p", default_branch: "develop"})

      assert wait_for_project_projection(project_id).default_branch == "develop"
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

  defp wait_for_project_projection(project_id) do
    poll_until(
      fn ->
        case ProjectionStore.project_projection(project_id) do
          %{project_id: ^project_id} = projection -> {:ok, projection}
          nil -> {:error, :missing}
        end
      end,
      "project projection #{project_id}"
    )
  end

  defp wait_for_project(project_id) do
    poll_until(
      fn ->
        case ProjectStore.get(project_id) do
          %{project_id: ^project_id} = project -> {:ok, project}
          nil -> {:error, :missing}
        end
      end,
      "project #{project_id}"
    )
  end

  defp wait_for_project_name(project_id, expected_name) do
    poll_until(
      fn ->
        projection = wait_for_project_projection(project_id)

        if projection.name == expected_name do
          {:ok, projection}
        else
          {:error, projection.name}
        end
      end,
      "project #{project_id} name #{expected_name}"
    )
  end

  defp poll_until_project_status(project_id, expected_status) do
    poll_until(
      fn ->
        projection = wait_for_project_projection(project_id)

        if projection.status == expected_status do
          {:ok, projection}
        else
          {:error, projection.status}
        end
      end,
      "project #{project_id} status #{expected_status}"
    )
  end

  defp receive_project_projection_event(project_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_receive_project_projection_event(project_id, deadline)
  end

  defp do_receive_project_projection_event(project_id, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:projection_event, %{data: data} = event} ->
        if Map.get(data, :project_id) == project_id or Map.get(data, "project_id") == project_id do
          event
        else
          do_receive_project_projection_event(project_id, deadline)
        end

      _other ->
        do_receive_project_projection_event(project_id, deadline)
    after
      remaining_ms ->
        flunk("timed out waiting for projection event for project #{project_id}")
    end
  end

  defp with_post_commit_readback_hook(hook, retry_delays_ms, fun)
       when is_function(hook, 3) and is_list(retry_delays_ms) and is_function(fun, 0) do
    previous_hook =
      Application.get_env(:foreman_server, :command_router_post_commit_readback_hook)

    previous_retry_delays_ms =
      Application.get_env(:foreman_server, :command_router_post_commit_retry_delays_ms)

    Application.put_env(:foreman_server, :command_router_post_commit_readback_hook, hook)

    Application.put_env(
      :foreman_server,
      :command_router_post_commit_retry_delays_ms,
      retry_delays_ms
    )

    try do
      fun.()
    after
      restore_env(:command_router_post_commit_readback_hook, previous_hook)
      restore_env(:command_router_post_commit_retry_delays_ms, previous_retry_delays_ms)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)

  defp poll_until(fun, message, timeout_ms \\ @poll_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(fun, deadline, message)
  end

  defp do_poll_until(fun, deadline, message) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{message} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_poll_until(fun, deadline, message)
        end
    end
  end
end
