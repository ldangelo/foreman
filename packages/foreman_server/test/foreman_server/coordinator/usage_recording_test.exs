defmodule ForemanServer.Coordinator.UsageRecordingTest do
  @moduledoc """
  foreman-ba4y4: the provider usage of a coordinator turn reaches the usage read
  model. The turn runner records what its agent reported through
  `coordinator.usage.record` (a coordinator event, NOT a run event), so
  `foreman usage --by role` lists the `coordinator` role and the project total
  includes its tokens: nil-preserving, replay-safe and never a run projection.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias ForemanServer.Aggregate
  alias ForemanServer.Coordinator.{Agent.Stub, Error, Turn}
  alias ForemanServer.Coordinator.Supervisor, as: CoordinatorSupervisor
  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, Usage, UsageDTO}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreadActions, FakeThreads, SpyGateway}

  @usage %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120, cost_usd: nil}

  defmodule RefusingGateway do
    @moduledoc "The spy gateway, except that it refuses `coordinator.usage.record`."
    alias ForemanServer.TestSupport.CoordinatorHelpers.SpyGateway

    def dispatch_system(%{type: "coordinator.usage.record"}), do: {:error, :usage_refused}
    def dispatch_system(command), do: SpyGateway.dispatch_system(command)
    def dispatch_system_approval(command), do: SpyGateway.dispatch_system_approval(command)
  end

  setup %{tmp_dir: dir} do
    project_id = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])
    H.subscribe!()

    on_exit(fn ->
      SpyGateway.unwatch()
      FakeThreads.clear()
      FakeThreadActions.clear()
    end)

    script = start_supervised!({Stub, responses: []})
    {:ok, project_id: project_id, script: script}
  end

  defp start_runtime(script, project_id, extra \\ []) do
    name = :"co_usage_rt_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      agent: Stub,
      agent_opts: [script: script],
      only: [project_id],
      gateway: SpyGateway,
      threads: FakeThreads,
      thread_actions: FakeThreadActions,
      retry_backoff_ms: 0,
      backfill?: false
    ]

    opts = Keyword.merge(defaults, extra)
    start_supervised!(Supervisor.child_spec({CoordinatorSupervisor, opts}, id: name))
    CoordinatorSupervisor.runtime(name, opts)
  end

  defp say(p, id, text) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "op-#{System.unique_integer([:positive])}",
        aggregate_id: "coordinator:#{p}",
        type: "coordinator.message",
        payload: %{project_id: p, message_id: id, text: text, source: "cli"}
      })
  end

  defp completed(p), do: H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))

  defp usage_events(p) do
    {:ok, events} = EventStore.read_stream_forward("coordinator:#{p}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == "CoordinatorUsageRecorded"))
  end

  # One answered turn whose agent reported `@usage`; returns the runtime.
  defp answered_turn(p, script) do
    Stub.push(script, [{:ok, %Turn{reply: "On it.", usage: @usage}}])
    rt = start_runtime(script, p)
    say(p, "m1", "the login page 500s")
    assert %{cursor_message_id: "m1"} = completed(p)
    rt
  end

  describe "a turn whose agent reported usage" do
    test "shows as role coordinator and in the project total; cost stays unknown, never 0",
         %{project_id: p, script: script} do
      rt = answered_turn(p, script)

      rollup = ProjectionStore.usage(p)
      assert Map.keys(rollup.by_role) == ["coordinator"]

      assert %{events: 1, cost_unknown_events: 1, usage: %Usage{total_tokens: 120}} =
               rollup.by_role["coordinator"]

      assert %{events: 1, cost_unknown_events: 1} = rollup.total
      assert rollup.total.usage.total_tokens == 120
      assert rollup.total.usage.cost_usd == nil
      assert rollup.total.usage == %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120}

      assert Map.keys(rollup.by_provider) == ["pi"]
      assert Map.keys(rollup.by_model) == [rt.default_model || "unknown"]
    end

    test "belongs to no thread, so by_thread, the thread count and the cache hints stay empty",
         %{project_id: p, script: script} do
      answered_turn(p, script)

      assert ProjectionStore.usage(p).by_thread == %{}
      assert {:ok, params} = UsageDTO.parse_params(%{})
      assert {:ok, dto} = UsageDTO.build(p, params, DateTime.utc_now())
      assert dto["thread_count"] == 0
      assert dto["by_thread"] == []
      assert dto["cache_hints"] == []
      assert %{"events" => 1, "total_tokens" => 120} = dto["totals"]
    end

    test "is listed by `foreman usage --by role` and counted in the project total",
         %{project_id: p, script: script} do
      answered_turn(p, script)

      assert {:ok, params} = UsageDTO.parse_params(%{"group_by" => "role"})
      assert {:ok, dto} = UsageDTO.build(p, params, DateTime.utc_now())

      assert [
               %{
                 "role" => "coordinator",
                 "events" => 1,
                 "input_tokens" => 100,
                 "output_tokens" => 20,
                 "total_tokens" => 120,
                 "cost_usd" => nil,
                 "cost_unknown_events" => 1
               }
             ] = dto["by_role"]

      assert %{"total_tokens" => 120, "cost_usd" => nil, "events" => 1} = dto["totals"]
      refute Map.has_key?(dto, "by_thread")
    end

    test "is one CoordinatorUsageRecorded on the coordinator stream and never a run projection",
         %{project_id: p, script: script} do
      rt = answered_turn(p, script)

      assert [event] = usage_events(p)
      assert Aggregate.get(event.data, :turn_id) == "m1:a1"
      assert Aggregate.get(event.data, :provider) == "pi"
      assert Aggregate.get(event.data, :model) == rt.default_model
      assert Aggregate.get(event.data, :total_tokens) == 120
      assert Aggregate.get(event.data, :cost_usd) == nil

      # a turn is not a run: nothing may plant a run projection the stall logic could act on
      assert ProjectionStore.run("m1:a1") == nil
      assert ProjectionStore.list_runs(project_id: p) == []
    end

    test "is recorded as the command the turn runner sends, with an id derived from the turn",
         %{project_id: p, script: script} do
      answered_turn(p, script)

      assert [{"coordinator.usage.record", command}] =
               for({"coordinator.usage.record", _} = spied <- SpyGateway.drain(), do: spied)

      assert command.command_id == "coordinator:usage:#{p}:m1:a1"
      assert %{turn_id: "m1:a1", provider: "pi", total_tokens: 120} = command.payload
    end
  end

  test "a failed turn still records the usage its agent reported, and fails as before",
       %{project_id: p, script: script} do
    usage = %Usage{input_tokens: 40, output_tokens: 2, total_tokens: 42}
    error = Error.new(:malformed_output, "no fenced json block in the reply", %{usage: usage})
    Stub.push(script, [{:error, error}])
    _rt = start_runtime(script, p)

    say(p, "m1", "hello")

    assert %{error_code: "malformed_output", turn_id: "m1:a1"} =
             H.await_event("CoordinatorTurnFailed", &(&1.project_id == p))

    # the retry (the exhausted script answers with a plain turn) completes the message
    assert %{cursor_message_id: "m1"} = completed(p)

    assert %{events: 1, usage: %Usage{total_tokens: 42}} =
             ProjectionStore.usage(p).by_role["coordinator"]

    assert [event] = usage_events(p)
    assert Aggregate.get(event.data, :turn_id) == "m1:a1"
  end

  test "an agent that reported no usage, or a provider that reported nothing, records nothing",
       %{project_id: p, script: script} do
    Stub.push(script, [{:ok, %Turn{reply: "one"}}, {:ok, %Turn{reply: "two", usage: %Usage{}}}])
    _rt = start_runtime(script, p)

    say(p, "m1", "first")
    assert %{cursor_message_id: "m1"} = completed(p)
    say(p, "m2", "second")
    assert %{cursor_message_id: "m2"} = completed(p)

    assert for({"coordinator.usage.record", _} = spied <- SpyGateway.drain(), do: spied) == []
    assert usage_events(p) == []

    rollup = ProjectionStore.usage(p)
    assert rollup.by_role == %{}
    assert rollup.total.events == 0
  end

  describe "bookkeeping never fails a turn" do
    test "a refused usage command is logged and the turn still completes",
         %{project_id: p, script: script} do
      Stub.push(script, [{:ok, %Turn{reply: "On it.", usage: @usage}}])

      log =
        capture_log(fn ->
          _rt = start_runtime(script, p, gateway: RefusingGateway)
          say(p, "m1", "hello")
          assert %{cursor_message_id: "m1"} = completed(p)
        end)

      assert log =~ "coordinator #{p}: turn m1:a1: usage not recorded: {:error, :usage_refused}"
      assert usage_events(p) == []
      assert ProjectionStore.usage(p).by_role == %{}
    end

    test "a usage of the wrong shape is ignored with a warning and the turn still completes",
         %{project_id: p, script: script} do
      Stub.push(script, [{:ok, %Turn{reply: "On it.", usage: %{input_tokens: 5}}}])

      log =
        capture_log(fn ->
          _rt = start_runtime(script, p)
          say(p, "m1", "hello")
          assert %{cursor_message_id: "m1"} = completed(p)
        end)

      assert log =~ "coordinator #{p}: turn m1:a1: ignored usage %{input_tokens: 5}"
      assert usage_events(p) == []
    end
  end

  describe "replay" do
    test "rebuilding the projection from the event log gives identical totals",
         %{project_id: p, script: script} do
      answered_turn(p, script)
      live = ProjectionStore.usage(p)
      assert live.total.events == 1

      assert :ok = ProjectionStore.rebuild([])
      assert ProjectionStore.usage(p) == live
    end

    test "re-applying the same event does not double count", %{project_id: p, script: script} do
      answered_turn(p, script)
      live = ProjectionStore.usage(p)

      assert [event] = usage_events(p)
      assert :ok = ProjectionStore.apply_events([event])
      assert :ok = ProjectionStore.apply_events([event])
      assert ProjectionStore.usage(p) == live
    end
  end

  describe "the fold" do
    defp recorded(p, turn_id, overrides \\ %{}) do
      payload =
        Map.merge(
          %{
            project_id: p,
            turn_id: turn_id,
            provider: "pi",
            model: "m1",
            input_tokens: 10,
            output_tokens: 5,
            total_tokens: 15,
            at: "2026-01-01T10:00:00.000000Z"
          },
          overrides
        )

      %{event_type: "CoordinatorUsageRecorded", payload: payload}
    end

    test "is keyed by turn: the same turn replaces, another turn adds", %{project_id: p} do
      replaced = recorded(p, "t1", %{total_tokens: 99})
      :ok = ProjectionStore.apply_events([recorded(p, "t1"), replaced])
      assert %{events: 1, usage: %Usage{total_tokens: 99}} = ProjectionStore.usage(p).total

      :ok = ProjectionStore.apply_events([recorded(p, "t2")])
      rollup = ProjectionStore.usage(p)
      assert %{events: 2, usage: %Usage{total_tokens: 114}} = rollup.by_role["coordinator"]
      assert Map.keys(rollup.by_day) == ["2026-01-01"]
      assert Map.keys(rollup.by_model) == ["m1"]
      assert Map.keys(rollup.by_provider) == ["pi"]
      assert rollup.by_thread == %{}
    end

    test "never touches a run projection", %{project_id: p} do
      turn_id = "turn-fold-#{System.unique_integer([:positive])}"
      :ok = ProjectionStore.apply_events([recorded(p, turn_id)])

      assert ProjectionStore.run(turn_id) == nil
      assert ProjectionStore.list_runs(project_id: p) == []
    end

    test "ignores a payload that cannot be decoded or reports nothing, without raising", %{
      project_id: p
    } do
      before = ProjectionStore.usage(p)
      garbage = %{input_tokens: "7", output_tokens: -3, total_tokens: nil, cost_usd: "free"}
      empty = %{input_tokens: nil, output_tokens: nil, total_tokens: nil}

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "CoordinatorUsageRecorded", payload: %{project_id: p}},
          recorded(p, "t-garbage", garbage),
          recorded(p, "t-empty", empty)
        ])

      assert ProjectionStore.usage(p) == before
    end
  end
end
