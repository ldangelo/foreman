defmodule ForemanServer.Aggregates.CoordinatorUsageTest do
  @moduledoc """
  `coordinator.usage.record`: the provider usage of the open turn. The pure
  aggregate rules first, then the command through the gateway: deduplicated by
  its deterministic command id, and never an operator command.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Aggregates.Coordinator
  alias ForemanServer.Aggregates.Coordinator.State
  alias ForemanServer.Events.CoordinatorUsageRecorded
  alias ForemanServer.{CommandGateway, EventCodec, EventStore}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H

  @p "proj-1"
  @record "coordinator.usage.record"
  @counts ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens)a

  defp cmd(type, payload), do: %{type: type, payload: Map.put_new(payload, :project_id, @p)}

  # Decide a command and apply its event, like the Actor does.
  defp run(state, type, payload) do
    case Coordinator.handle_command(state, cmd(type, payload)) do
      {:ok, nil} -> {:noop, state}
      {:ok, spec} -> {spec, Coordinator.apply_event(state, spec)}
      other -> other
    end
  end

  defp ok!(state, type, payload) do
    {%{} = spec, state} = run(state, type, payload)
    {spec, state}
  end

  defp record(state, payload), do: run(state, @record, payload)

  defp open_turn(turn_id \\ "t1") do
    start = %{turn_id: turn_id, attempt: 1, trigger_message_ids: ["m1"]}
    {_, state} = ok!(Coordinator.initial_state(), "coordinator.turn.start", start)
    state
  end

  defp usage(overrides \\ %{}) do
    base = %{
      turn_id: "t1",
      provider: "pi",
      model: "m1",
      input_tokens: 100,
      output_tokens: 20,
      total_tokens: 120
    }

    Map.merge(base, overrides)
  end

  describe "the aggregate" do
    test "emits one CoordinatorUsageRecorded with the given facts and no conversation change" do
      state = open_turn()
      {spec, after_state} = ok!(state, @record, usage(%{cache_read_tokens: 7, cost_usd: 0.25}))

      assert spec.stream_id == "coordinator:proj-1"
      assert spec.event_type == "CoordinatorUsageRecorded"

      assert %{
               project_id: "proj-1",
               turn_id: "t1",
               provider: "pi",
               model: "m1",
               input_tokens: 100,
               output_tokens: 20,
               cache_read_tokens: 7,
               cache_write_tokens: nil,
               total_tokens: 120,
               cost_usd: 0.25,
               at: at
             } = spec.payload

      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(at)

      # the turn stays open: recording usage is bookkeeping, not a turn transition
      assert after_state == state
      assert %State{open_turn: %{turn_id: "t1"}, status: :turn_open} = after_state
    end

    test "the event is registered and its payload decodes into the typed struct" do
      assert "CoordinatorUsageRecorded" in EventCodec.registered()
      {spec, _} = ok!(open_turn(), @record, usage(%{cost_usd: 0.5}))

      assert %CoordinatorUsageRecorded{
               project_id: "proj-1",
               turn_id: "t1",
               provider: "pi",
               model: "m1",
               total_tokens: 120,
               cost_usd: 0.5
             } = EventCodec.decode!("CoordinatorUsageRecorded", spec.payload)
    end

    test "an unreported field stays nil, a reported zero stays zero, an integer cost is float" do
      payload = %{turn_id: "t1", provider: "pi", output_tokens: 0, cost_usd: 0}
      {spec, _} = ok!(open_turn(), @record, payload)

      assert %{model: nil, input_tokens: nil, total_tokens: nil} = spec.payload
      assert spec.payload.output_tokens === 0
      assert spec.payload.cost_usd === 0.0
    end

    test "refuses a usage with nothing reported (an all-nil event would read as unknown)" do
      assert {:error, {:missing_or_invalid, :usage}} =
               record(open_turn(), %{turn_id: "t1", provider: "pi"})

      all_nil = Map.new([:cost_usd | @counts], &{&1, nil})
      payload = Map.merge(%{turn_id: "t1", provider: "pi"}, all_nil)
      assert {:error, {:missing_or_invalid, :usage}} = record(open_turn(), payload)
    end

    test "refuses a negative or non-integer count and a negative or non-numeric cost" do
      for field <- @counts, bad <- [-1, 1.5, "10"] do
        result = record(open_turn(), usage(%{field => bad}))
        assert result == {:error, {:missing_or_invalid, field}}, "#{field} = #{inspect(bad)}"
      end

      for bad <- [-0.5, "0.1"] do
        result = record(open_turn(), usage(%{cost_usd: bad}))
        assert result == {:error, {:missing_or_invalid, :cost_usd}}, "cost_usd = #{inspect(bad)}"
      end
    end

    test "refuses a blank or missing project, turn id, provider or model" do
      s = open_turn()
      no_provider = Map.delete(usage(), :provider)
      no_turn_id = Map.delete(usage(), :turn_id)

      assert {:error, {:missing_or_invalid, :provider}} = record(s, usage(%{provider: ""}))
      assert {:error, {:missing_or_invalid, :provider}} = record(s, no_provider)
      assert {:error, {:missing_or_invalid, :turn_id}} = record(s, usage(%{turn_id: ""}))
      assert {:error, {:missing_or_invalid, :turn_id}} = record(s, no_turn_id)
      assert {:error, {:missing_or_invalid, :project_id}} = record(s, usage(%{project_id: ""}))
      assert {:error, {:missing_or_invalid, :model}} = record(s, usage(%{model: ""}))
    end

    test "needs the open turn: no turn, another turn and a finished turn are all turn_not_open" do
      assert {:error, {:turn_not_open, "t1"}} = record(Coordinator.initial_state(), usage())
      assert {:error, {:turn_not_open, "other"}} = record(open_turn(), usage(%{turn_id: "other"}))

      complete = %{turn_id: "t1", cursor_message_id: "m1"}
      {_, finished} = ok!(open_turn(), "coordinator.turn.complete", complete)
      assert {:error, {:turn_not_open, "t1"}} = record(finished, usage())
    end
  end

  describe "through the gateway" do
    setup %{tmp_dir: dir}, do: {:ok, project_id: H.register_project(dir)}

    defp system(project_id, type, payload, command_id) do
      CommandGateway.dispatch_system(%{
        command_id: command_id,
        aggregate_id: "coordinator:#{project_id}",
        type: type,
        payload: Map.put(payload, :project_id, project_id)
      })
    end

    defp usage_events(project_id) do
      {:ok, events} = EventStore.read_stream_forward("coordinator:#{project_id}", 0, 100)
      Enum.filter(events, &(&1.event_type == "CoordinatorUsageRecorded"))
    end

    defp start_turn(project_id) do
      start = %{turn_id: "t1", attempt: 1, trigger_message_ids: ["m1"]}
      {:ok, _} = system(project_id, "coordinator.turn.start", start, "ts-#{project_id}")
    end

    test "a duplicate command id appends nothing, even once the turn has closed", %{
      project_id: p
    } do
      start_turn(p)
      id = "uc-#{p}"

      assert {:ok, %{"event_type" => "CoordinatorUsageRecorded"}} =
               system(p, @record, usage(), id)

      assert {:ok, _} = system(p, @record, usage(), id)
      assert length(usage_events(p)) == 1

      complete = %{turn_id: "t1", cursor_message_id: "m1"}
      {:ok, _} = system(p, "coordinator.turn.complete", complete, "tc-#{p}")

      # The actor finds the persisted event before it decides, so a replay after the
      # turn closed is still a no-op rather than `turn_not_open`.
      assert {:ok, _} = system(p, @record, usage(), id)
      assert length(usage_events(p)) == 1
    end

    test "the actor refuses an invalid usage and an unknown turn, appending nothing", %{
      project_id: p
    } do
      start_turn(p)

      assert {:error, {:missing_or_invalid, :usage}} =
               system(p, @record, %{turn_id: "t1", provider: "pi"}, "bad-usage-#{p}")

      assert {:error, {:turn_not_open, "ghost"}} =
               system(p, @record, usage(%{turn_id: "ghost"}), "bad-turn-#{p}")

      assert usage_events(p) == []
    end

    test "is not an operator command: the gateway refuses it and nothing is appended", %{
      project_id: p
    } do
      start_turn(p)

      assert {:error, {:command_not_allowed, @record}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "op-#{System.unique_integer([:positive])}",
                 aggregate_id: "coordinator:#{p}",
                 type: @record,
                 payload: Map.put(usage(), :project_id, p)
               })

      assert usage_events(p) == []
    end
  end
end
