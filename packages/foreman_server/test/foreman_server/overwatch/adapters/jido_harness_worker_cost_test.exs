defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerCostTest do
  @moduledoc """
  What the workflow door records as the cost of a claude run (foreman-g5u3h).

  The claude CLI estimates a cost with its own price table. For a model name it has no price for
  (a LiteLLM alias such as `Minimax-M3`) it prices the tokens at ITS DEFAULT MODEL'S rate and says
  so in its `result` record (`modelUsage.<model>.costBasis: "unknown"`). Foreman recorded that
  figure as `UsageRecorded.cost_usd`: 2.6087 USD for two runs the gateway itself priced at 0.28
  (docs/acceptance/context-window-live-run.md).

  The runs here are REAL harness runs of the claude adapter, against a CLI that replays records
  captured from the real one (`jido_harness/test/support/fixtures`): `claude_live_unknown_model.jsonl`
  is claude 2.1.309 answering `Minimax-M3`, `claude_live_input.jsonl` is claude 2.1.308 answering
  `claude-haiku-5-5`, a model it prices. Each finished run is read the way the workflow door reads
  it (`JidoHarnessWorker.build_meta/2`) and recorded by a worker.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.UsageDTO
  alias ForemanServer.Workflow.LiveSteer

  @gateway_model "Minimax-M3"
  @gateway_recording "claude_live_unknown_model.jsonl"
  @direct_model "claude-haiku-5-5"
  @direct_recording "claude_live_input.jsonl"

  setup do
    fixtures = Path.join([Mix.Project.deps_paths()[:jido_harness], "test", "support", "fixtures"])
    original = Application.get_env(:jido_harness, :provider_config, %{})

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(original, :claude, %{cli_path: Path.join(fixtures, "fake_claude_live.py")})
    )

    on_exit(fn -> Application.put_env(:jido_harness, :provider_config, original) end)

    start_supervised!({Tracker, []}, id: :tracker)
    :ok
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  # The `UsageRecorded` a worker writes after a real harness run that replayed `recording`.
  defp recorded_usage(recording, model) do
    worker_id = uuid()
    run_id = uuid()

    driver_opts =
      LiveSteer.put_driver_opts(
        [
          cwd: System.tmp_dir!(),
          timeout: 60_000,
          env: %{"FAKE_CLAUDE_RECORDING" => recording, "TURN_SECONDS" => "0"}
        ],
        :claude
      )

    assert {:ok, %Jido.Harness.RunResult{status: :completed} = run_result} =
             Driver.run(:claude, "first", driver_opts)

    pid =
      start_supervised!(%{
        id: {JidoHarnessWorker, worker_id},
        start:
          {JidoHarnessWorker, :start_link,
           [
             [
               worker_id: worker_id,
               run_id: run_id,
               provider: :claude,
               prompt: "first",
               project_id: "proj-cost",
               task_id: "task-#{run_id}",
               driver_opts: [model: model]
             ]
           ]},
        restart: :temporary
      })

    ref = Process.monitor(pid)
    send(pid, {:agent_done, {:ok, "done"}, [], JidoHarnessWorker.build_meta(:claude, run_result)})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    {:ok, events} = Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    assert [%{data: data}] = Enum.filter(events, &(&1.event_type == "UsageRecorded"))
    data
  end

  test "a model the CLI has no price for: the tokens are recorded and the CLI's guess is not" do
    data = recorded_usage(@gateway_recording, @gateway_model)

    assert %{
             "model" => @gateway_model,
             "input_tokens" => 67_378,
             "cache_read_tokens" => 71_824,
             "cache_write_tokens" => 0,
             "output_tokens" => 406,
             "total_tokens" => 67_784
           } = data

    assert data["cost_usd"] == nil
  end

  test "a model the CLI prices: the CLI's cost is recorded unchanged (positive control)" do
    data = recorded_usage(@direct_recording, @direct_model)

    assert %{
             "model" => @direct_model,
             "input_tokens" => 2,
             "cache_read_tokens" => 13_852,
             "cache_write_tokens" => 17_580,
             "output_tokens" => 3
           } = data

    assert data["cost_usd"] == 0.00365622
  end

  describe "a project that ran both" do
    setup do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectRegistered",
            payload: %{project_id: "proj-cost", path: "/tmp/proj-cost"}
          }
        ])
    end

    test "its cost is the priced run's alone, the other run is counted unpriced, and both runs' tokens are counted" do
      gateway = recorded_usage(@gateway_recording, @gateway_model)
      direct = recorded_usage(@direct_recording, @direct_model)

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "UsageRecorded", payload: gateway},
          %{event_type: "UsageRecorded", payload: direct}
        ])

      assert {:ok, params} = UsageDTO.parse_params(%{})
      assert {:ok, dto} = UsageDTO.build("proj-cost", params, DateTime.utc_now())

      assert %{
               "events" => 2,
               "cost_usd" => 0.00365622,
               "cost_unknown_events" => 1,
               "total_tokens" => 67_789
             } = dto["totals"]

      assert %{"cost_usd" => nil, "cost_unknown_events" => 1, "total_tokens" => 67_784} =
               Enum.find(dto["by_model"], &(&1["model"] == @gateway_model))

      assert %{"cost_usd" => 0.00365622, "cost_unknown_events" => 0, "total_tokens" => 5} =
               Enum.find(dto["by_model"], &(&1["model"] == @direct_model))
    end
  end
end
