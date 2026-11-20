defmodule ForemanServer.Aggregates.RunSlotsPromoteTest do
  @moduledoc """
  TRD-003-TEST: `run_slots.promote`, `force` / `enqueue_only` acquire flags and
  the waiter drop in the `RunSlotAcquired` fold. Pure aggregate tests: commands
  are decided against state and the resulting events folded back in, exactly as
  the actor does.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Events.{RunSlotAcquired, RunSlotQueued, RunSlotReleased}

  @project "p1"

  defp apply_all(events, state \\ RunSlots.initial_state()),
    do: Enum.reduce(events, state, &RunSlots.apply_event(&2, &1))

  defp cmd(type, payload),
    do: %{type: type, payload: Map.put(payload, :project_id, @project)}

  defp run(state, type, payload) do
    {:ok, event} = RunSlots.handle_command(state, cmd(type, payload))
    {event, if(event, do: RunSlots.apply_event(state, event), else: state)}
  end

  defp acquire(state, run_id, capacity, extra \\ %{}),
    do: run(state, "run_slots.acquire", Map.merge(%{run_id: run_id, capacity: capacity}, extra))

  defp promote(state, capacity), do: run(state, "run_slots.promote", %{capacity: capacity})

  defp waiter_ids(state), do: Enum.map(state.waiters, & &1.run_id)

  # Fill `n` holders then queue the named waiters at `capacity`.
  defp fill(holders, waiters, capacity) do
    state =
      Enum.reduce(holders, RunSlots.initial_state(), fn id, st ->
        {%RunSlotAcquired{}, st} = acquire(st, id, capacity)
        st
      end)

    Enum.reduce(waiters, state, fn id, st ->
      {%RunSlotQueued{}, st} = acquire(st, id, capacity)
      st
    end)
  end

  describe "promote" do
    test "AC-003-3: raising the limit starts waiters in order" do
      state = fill(~w(h1 h2 h3), ~w(w1 w2), 3)
      assert waiter_ids(state) == ~w(w1 w2)

      {e1, state} = promote(state, 5)
      assert %RunSlotAcquired{run_id: "w1", promoted: true, capacity: 5, project_id: @project} = e1

      {e2, state} = promote(state, 5)
      assert %RunSlotAcquired{run_id: "w2", promoted: true} = e2

      assert state.waiters == []
      assert state.holders |> Map.keys() |> Enum.sort() == ~w(h1 h2 h3 w1 w2)
    end

    test "promote with no free capacity or no waiters is a no-op" do
      full = fill(~w(h1 h2 h3), ~w(w1), 3)
      assert {nil, ^full} = promote(full, 3)

      empty_queue = fill(~w(h1), [], 3)
      assert {nil, ^empty_queue} = promote(empty_queue, 3)
    end

    test "promote needs a valid capacity" do
      state = fill(~w(h1), ~w(w1), 1)

      assert {:error, {:missing_or_invalid, :capacity}} =
               RunSlots.handle_command(state, cmd("run_slots.promote", %{}))
    end

    test "AC-005-1: waiters X, Y, Z start in FIFO order as slots free one at a time" do
      state = fill(~w(h1 h2 h3), ~w(x y z), 3)

      {started, state} =
        Enum.reduce(~w(h1 h2 h3), {[], state}, fn holder, {acc, st} ->
          {event, st} = run(st, "run_slots.release", %{run_id: holder, capacity: 3})
          assert %{released_run_id: ^holder, acquired_run_id: next} = event
          {acc ++ [next], st}
        end)

      assert started == ~w(x y z)
      assert state.waiters == []
    end

    test "AC-005-1: promote after plain releases also starts in FIFO order" do
      state = fill(~w(h1 h2 h3), ~w(x y z), 3)

      # Free all three holders without transfers, then promote one by one.
      state =
        Enum.reduce(~w(h1 h2 h3), state, fn id, st ->
          RunSlots.apply_event(st, %RunSlotReleased{run_id: id, capacity: 3})
        end)

      {order, state} =
        Enum.reduce(1..3, {[], state}, fn _, {acc, st} ->
          {%RunSlotAcquired{run_id: id}, st} = promote(st, 3)
          {acc ++ [id], st}
        end)

      assert order == ~w(x y z)
      assert state.waiters == []
    end
  end

  describe "RunSlotAcquired fold" do
    test "drops the run from waiters (typed and recorded shapes)" do
      state = fill(~w(h1), ~w(w1 w2), 1)
      acquired = %RunSlotAcquired{run_id: "w1", capacity: 3, acquired_at_ms: 5, promoted: true}

      typed = RunSlots.apply_event(state, acquired)
      assert waiter_ids(typed) == ~w(w2)
      assert Map.has_key?(typed.holders, "w1")

      recorded = %EventStore.RecordedEvent{
        event_type: "RunSlotAcquired",
        data: Map.from_struct(acquired)
      }

      assert waiter_ids(RunSlots.apply_event(state, recorded)) == ~w(w2)
    end

    test "a run that was never a waiter leaves waiters unchanged" do
      state = fill(~w(h1 h2 h3), ~w(w1), 3)
      acquired = %RunSlotAcquired{run_id: "other", capacity: 3, acquired_at_ms: 5}
      assert waiter_ids(RunSlots.apply_event(state, acquired)) == ~w(w1)
    end
  end

  describe "acquire flags" do
    test "AC-009-4: force records a holder over capacity" do
      state = fill(~w(h1 h2 h3), [], 3)
      {event, state} = acquire(state, "adopted", 3, %{force: true})

      assert %RunSlotAcquired{run_id: "adopted"} = event
      assert map_size(state.holders) == 4
    end

    test "AC-009-4: after force adoption over capacity new runs wait until below the limit" do
      state = fill(~w(h1 h2 h3), [], 3)
      {_, state} = acquire(state, "adopted1", 3, %{force: true})
      {_, state} = acquire(state, "adopted2", 3, %{force: true})
      assert map_size(state.holders) == 5

      {event, state} = acquire(state, "new1", 3)
      assert %RunSlotQueued{run_id: "new1"} = event

      # still over the limit: nothing promotes
      assert {nil, ^state} = promote(state, 3)

      # drop to the limit exactly: still not below it
      state = release_quietly(state, ~w(h1 h2))
      assert map_size(state.holders) == 3
      assert {nil, ^state} = promote(state, 3)

      # below the limit: the waiter starts
      state = release_quietly(state, ~w(h3))
      {event, state} = promote(state, 3)
      assert %RunSlotAcquired{run_id: "new1", promoted: true} = event
      assert map_size(state.holders) == 3
    end

    test "force on an existing holder is still a no-op" do
      state = fill(~w(h1), [], 3)
      assert {nil, ^state} = acquire(state, "h1", 3, %{force: true})
    end

    test "enqueue_only queues even when capacity is free" do
      state = fill(~w(h1), [], 3)
      {event, state} = acquire(state, "w1", 3, %{enqueue_only: true})

      assert %RunSlotQueued{run_id: "w1", position: 1} = event
      assert waiter_ids(state) == ~w(w1)
      assert map_size(state.holders) == 1
    end

    test "enqueue_only keeps queue order and can be promoted" do
      state = fill([], [], 3)
      {_, state} = acquire(state, "a", 3, %{enqueue_only: true})
      {_, state} = acquire(state, "b", 3, %{enqueue_only: true})
      {%RunSlotAcquired{run_id: "a"}, state} = promote(state, 3)
      {%RunSlotAcquired{run_id: "b"}, _} = promote(state, 3)
    end
  end

  describe "no double entry (AC-007-3)" do
    test "a holder requesting again holds at most one slot" do
      state = fill(~w(h1), [], 3)
      assert {nil, ^state} = acquire(state, "h1", 3)
      assert map_size(state.holders) == 1
    end

    test "a queued run requesting again holds at most one position" do
      state = fill(~w(h1), ~w(w1), 1)
      assert {nil, ^state} = acquire(state, "w1", 1)
      assert waiter_ids(state) == ~w(w1)
    end

    test "a queued run requesting with enqueue_only or force again is still single" do
      state = fill(~w(h1), ~w(w1), 1)
      assert {nil, ^state} = acquire(state, "w1", 1, %{enqueue_only: true})
      assert {nil, ^state} = acquire(state, "w1", 1, %{force: true})
      assert waiter_ids(state) == ~w(w1)
      refute Map.has_key?(state.holders, "w1")
    end
  end

  describe "exactly one winner (AC-007-2)" do
    test "two simultaneous acquires for one free slot: one holds, one waits" do
      # The actor serialises commands through its mailbox; model it with an
      # Agent that decides and folds one command at a time.
      {:ok, actor} = Agent.start_link(fn -> fill(~w(h1 h2), [], 3) end)

      request = fn run_id ->
        Agent.get_and_update(actor, fn st ->
          {event, st2} = acquire(st, run_id, 3)
          {event, st2}
        end)
      end

      results =
        ~w(r1 r2)
        |> Enum.map(&Task.async(fn -> request.(&1) end))
        |> Task.await_many()

      assert Enum.count(results, &match?(%RunSlotAcquired{}, &1)) == 1
      assert Enum.count(results, &match?(%RunSlotQueued{}, &1)) == 1

      state = Agent.get(actor, & &1)
      assert map_size(state.holders) == 3
      assert length(state.waiters) == 1
    end
  end

  describe "restart keeps the queue (AC-005-2)" do
    test "rebuilding from the stream keeps waiter order with none lost or duplicated" do
      {events, live} =
        Enum.reduce(~w(h1 h2 w1 w2 w3), {[], RunSlots.initial_state()}, fn id, {evs, st} ->
          {e, st} = acquire(st, id, 2)
          {evs ++ [e], st}
        end)

      # a duplicate request mid-stream and a promote/release round
      assert {nil, ^live} = acquire(live, "w2", 2)
      {rel, live} = run(live, "run_slots.release", %{run_id: "h1", capacity: 2})
      events = events ++ [rel]

      expected = waiter_ids(live)
      assert expected == ~w(w2 w3)

      typed = apply_all(events)
      assert waiter_ids(typed) == expected
      assert typed == live

      # "kill the actor": rebuild from persisted (recorded) events
      recorded =
        Enum.map(events, fn e ->
          %EventStore.RecordedEvent{
            event_type: e.__struct__ |> Module.split() |> List.last(),
            data: Map.from_struct(e)
          }
        end)

      rebuilt = apply_all(recorded)
      assert waiter_ids(rebuilt) == expected
      assert Enum.uniq(waiter_ids(rebuilt)) == waiter_ids(rebuilt)
      assert rebuilt.holders == live.holders
    end

    test "promoted waiters survive a rebuild in order" do
      {events, live} =
        Enum.reduce(~w(h1 w1 w2 w3), {[], RunSlots.initial_state()}, fn id, {evs, st} ->
          {e, st} = acquire(st, id, 1)
          {evs ++ [e], st}
        end)

      {p, live} = promote(live, 2)
      assert %RunSlotAcquired{run_id: "w1"} = p

      rebuilt = apply_all(events ++ [p])
      assert waiter_ids(rebuilt) == ~w(w2 w3)
      assert rebuilt == live
    end
  end

  defp release_quietly(state, ids) do
    Enum.reduce(ids, state, fn id, st ->
      RunSlots.apply_event(st, %RunSlotReleased{run_id: id, capacity: 3})
    end)
  end
end
