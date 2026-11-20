defmodule ForemanServer.ProjectionStoreQueueStatusTest do
  # `ProjectionStore.queue_status/1` (TRD-011): one project's running count,
  # waiting count, limit and waiting runs in order with `waited_ms`.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @now_ms 1_700_000_000_000

  setup_all do
    original = Application.get_env(:foreman_server, :projection_store_now_ms)
    Application.put_env(:foreman_server, :projection_store_now_ms, fn -> @now_ms end)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:foreman_server, :projection_store_now_ms),
        else: Application.put_env(:foreman_server, :projection_store_now_ms, original)
    end)

    :ok
  end

  setup do
    ProjectionStoreReset.reset!(keep_subscribers: true)
    on_exit(fn -> ProjectionStoreReset.reset!(keep_subscribers: true) end)
    :ok
  end

  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp register(id, config \\ %{}),
    do: %{
      event_type: "ProjectRegistered",
      payload: %{project_id: id, path: "/tmp/#{id}", config: config}
    }

  defp acquired(project, run, capacity, at),
    do: %{
      event_type: "RunSlotAcquired",
      payload: %{project_id: project, run_id: run, capacity: capacity, acquired_at_ms: at}
    }

  defp queued(project, run, position, at),
    do: %{
      event_type: "RunSlotQueued",
      payload: %{project_id: project, run_id: run, position: position, enqueued_at_ms: at}
    }

  defp three_running_two_waiting(project) do
    [
      register(project, %{max_concurrent_runs: 3}),
      acquired(project, "#{project}-r1", 3, 100),
      acquired(project, "#{project}-r2", 3, 101),
      acquired(project, "#{project}-r3", 3, 102),
      queued(project, "#{project}-w1", 1, @now_ms - 5_000),
      queued(project, "#{project}-w2", 2, @now_ms - 2_000)
    ]
  end

  describe "counts, limit and order (AC-010-1)" do
    test "three running and two waiting report running 3, waiting 2, limit 3, waiters in order" do
      apply!(three_running_two_waiting("p1"))

      status = ProjectionStore.queue_status("p1")

      assert status.running_runs == 3
      assert status.waiting_runs == 2
      assert status.limit == 3
      assert Enum.sort(status.running) == ["p1-r1", "p1-r2", "p1-r3"]
      assert Enum.map(status.waiting, & &1.run_id) == ["p1-w1", "p1-w2"]
    end

    test "a promotion moves the head waiter into running and keeps the rest in order" do
      apply!(three_running_two_waiting("p1"))

      apply!([
        %{
          event_type: "RunSlotTransferred",
          payload: %{
            project_id: "p1",
            released_run_id: "p1-r1",
            acquired_run_id: "p1-w1",
            capacity: 3,
            acquired_at_ms: @now_ms
          }
        }
      ])

      status = ProjectionStore.queue_status("p1")
      assert status.running_runs == 3
      assert status.waiting_runs == 1
      assert Enum.map(status.waiting, & &1.run_id) == ["p1-w2"]
    end
  end

  describe "no cross-project leakage (AC-010-2)" do
    test "reading one project never includes the other's runs" do
      apply!(three_running_two_waiting("p1") ++ three_running_two_waiting("p2"))

      p1 = ProjectionStore.queue_status("p1")
      p2 = ProjectionStore.queue_status("p2")

      assert Enum.all?(p1.running, &String.starts_with?(&1, "p1-"))
      assert Enum.all?(p1.waiting, &String.starts_with?(&1.run_id, "p1-"))
      assert Enum.all?(p2.running, &String.starts_with?(&1, "p2-"))
      assert Enum.all?(p2.waiting, &String.starts_with?(&1.run_id, "p2-"))
      assert p1.running_runs == 3 and p2.running_runs == 3
    end

    test "a release in one project does not change another" do
      apply!(three_running_two_waiting("p1") ++ three_running_two_waiting("p2"))

      apply!([
        %{event_type: "RunSlotReleased", payload: %{project_id: "p1", run_id: "p1-r1"}}
      ])

      assert ProjectionStore.queue_status("p1").running_runs == 2
      assert ProjectionStore.queue_status("p2").running_runs == 3
    end
  end

  describe "limit is the setting (AC-010-3)" do
    test "a setting of 5 is reported as 5, not clamped" do
      apply!([register("p1", %{max_concurrent_runs: 5}), acquired("p1", "r1", 5, 100)])

      assert ProjectionStore.queue_status("p1").limit == 5
    end

    test "a setting above the retired global ceiling is not lowered" do
      apply!([register("p1", %{max_concurrent_runs: 50})])

      assert ProjectionStore.queue_status("p1").limit == 50
    end
  end

  describe "wait time shown (AC-010-4)" do
    test "each waiter carries waited_ms measured from its enqueue stamp" do
      apply!(three_running_two_waiting("p1"))

      assert [%{run_id: "p1-w1", waited_ms: 5_000}, %{run_id: "p1-w2", waited_ms: 2_000}] =
               ProjectionStore.queue_status("p1").waiting
    end

    test "waited_ms is never negative when a stamp is ahead of the clock" do
      apply!([queued("p1", "w1", 1, @now_ms + 9_000)])

      assert [%{waited_ms: 0}] = ProjectionStore.queue_status("p1").waiting
    end
  end

  describe "limit changes replay deterministically (AC-013-2)" do
    @history [
      {"RunSlotAcquired", %{run_id: "r1", capacity: 2}},
      {"RunSlotAcquired", %{run_id: "r2", capacity: 2}},
      {"RunSlotQueued", %{run_id: "w1", position: 1, enqueued_at_ms: 200}},
      # limit raised 2 -> 4: the waiter acquires with the new capacity
      {"RunSlotAcquired", %{run_id: "w1", capacity: 4, promoted: true}},
      {"RunSlotAcquired", %{run_id: "r3", capacity: 4}}
    ]

    defp history_events do
      for {type, payload} <- @history do
        payload = Map.merge(%{project_id: "p1", acquired_at_ms: 100}, payload)
        %{event_type: type, payload: payload}
      end
    end

    test "each step shows the limit in force at that point of the history" do
      limits =
        for event <- history_events() do
          apply!([event])
          ProjectionStore.queue_status("p1").limit
        end

      assert limits == [2, 2, 2, 4, 4]
    end

    test "replaying the same history from scratch yields the same status" do
      apply!(history_events())
      first = ProjectionStore.queue_status("p1")

      ProjectionStoreReset.reset!(keep_subscribers: true)
      apply!(history_events())

      assert ProjectionStore.queue_status("p1") == first
      assert first.limit == 4
      assert first.running_runs == 4
      assert first.waiting_runs == 0
    end
  end
end
