defmodule ForemanServer.Aggregates.RunSlotsProjectScopedTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{RunSlotAcquired, RunSlotQueued, RunSlotReleased}

  defp acquire(state, project_id, run_id, capacity \\ 3) do
    cmd = %{
      type: "run_slots.acquire",
      payload: %{project_id: project_id, run_id: run_id, capacity: capacity}
    }

    {:ok, event} = RunSlots.handle_command(state, cmd)
    {event, RunSlots.apply_event(state, event)}
  end

  test "stream id is keyed by project" do
    assert RunSlots.stream_id("a") == "run_slots:a"
  end

  test "legacy RunSlotAcquired without project_id decodes and folds" do
    data = %{"run_id" => "r1", "capacity" => 3, "acquired_at_ms" => 100}
    event = EventCodec.decode!("RunSlotAcquired", data)
    assert %RunSlotAcquired{project_id: nil, promoted: nil} = event
    state = RunSlots.apply_event(RunSlots.initial_state(), event)
    assert %{"r1" => %{acquired_at_ms: 100}} = state.holders
  end

  test "acquire carries project_id and a wall-clock stamp" do
    before_ms = System.system_time(:millisecond)
    {event, _} = acquire(RunSlots.initial_state(), "a", "r1")
    assert %RunSlotAcquired{project_id: "a", acquired_at_ms: at} = event
    assert at >= before_ms
  end

  test "queue and release events carry project_id" do
    state = RunSlots.initial_state()
    {_, state} = acquire(state, "a", "r1", 1)
    {queued, state} = acquire(state, "a", "r2", 1)
    assert %RunSlotQueued{project_id: "a"} = queued
    assert state.waiters != []

    {:ok, rel} =
      RunSlots.handle_command(RunSlots.initial_state() |> then(fn _ -> state end), %{
        type: "run_slots.release",
        payload: %{project_id: "a", run_id: "r1", capacity: 1}
      })

    assert %{project_id: "a"} = rel
  end

  test "release without waiters carries project_id" do
    {_, state} = acquire(RunSlots.initial_state(), "a", "r1")

    {:ok, rel} =
      RunSlots.handle_command(state, %{
        type: "run_slots.release",
        payload: %{project_id: "a", run_id: "r1", capacity: 3}
      })

    assert %RunSlotReleased{project_id: "a"} = rel
  end

  test "two project streams fill independently" do
    {sa, sb} =
      Enum.reduce(1..3, {RunSlots.initial_state(), RunSlots.initial_state()}, fn i, {a, b} ->
        {ea, a} = acquire(a, "a", "a#{i}")
        {eb, b} = acquire(b, "b", "b#{i}")
        assert %RunSlotAcquired{} = ea
        assert %RunSlotAcquired{} = eb
        {a, b}
      end)

    assert map_size(sa.holders) == 3 and map_size(sb.holders) == 3
    assert sa.waiters == [] and sb.waiters == []

    {queued, sa} = acquire(sa, "a", "a4")
    assert %RunSlotQueued{project_id: "a"} = queued
    assert length(sa.waiters) == 1
    assert sb.waiters == []
  end

  test "rebuild from events equals live state" do
    {events, live} =
      Enum.reduce(1..4, {[], RunSlots.initial_state()}, fn i, {evs, st} ->
        {e, st} = acquire(st, "a", "r#{i}")
        {evs ++ [e], st}
      end)

    rebuilt = Enum.reduce(events, RunSlots.initial_state(), &RunSlots.apply_event(&2, &1))
    assert rebuilt == live
  end
end
