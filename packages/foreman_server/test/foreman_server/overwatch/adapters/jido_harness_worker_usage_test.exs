defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerUsageTest do
  @moduledoc """
  The workflow door dropped token usage and cost entirely. These tests pin that
  a finished worker records one `UsageRecorded` before `WorkerExited` (failed
  runs included, because their tokens were spent), records nothing when the
  provider reported nothing, and that the run projection sums usage across
  phases.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.{RunMeta, Tracker}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Usage

  @claude_usage %{
    "input_tokens" => 10,
    "output_tokens" => 5,
    "cache_read_input_tokens" => 100,
    "cache_creation_input_tokens" => 20
  }

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp meta(attrs) do
    struct!(%RunMeta{provider: :claude, run_status: :completed}, attrs)
  end

  describe "build_meta/2" do
    test "collects the run's usage events in order" do
      events =
        for n <- [1, 2] do
          %Jido.Harness.Event{
            type: :usage,
            provider: :pi,
            payload: %{"input" => n},
            timestamp: "2026-01-01T00:00:00Z"
          }
        end

      result = %Jido.Harness.RunResult{
        run_id: "r",
        provider: :pi,
        status: :completed,
        events: events,
        usage: %{"input" => 2}
      }

      assert %RunMeta{usage: %{"input" => 2}, usage_events: [%{"input" => 1}, %{"input" => 2}]} =
               JidoHarnessWorker.build_meta(:pi, result)
    end
  end

  describe "worker stream" do
    setup do
      start_supervised!({Tracker, []}, id: :tracker)
      {:ok, worker_id: uuid(), run_id: uuid()}
    end

    defp start_worker(worker_id, run_id) do
      opts = [
        worker_id: worker_id,
        run_id: run_id,
        provider: :claude,
        prompt: "p",
        project_id: "proj-1",
        task_id: "task-1",
        driver_opts: [model: "opus"]
      ]

      start_supervised!(%{
        id: {JidoHarnessWorker, worker_id},
        start: {JidoHarnessWorker, :start_link, [opts]},
        restart: :temporary
      })
    end

    defp deliver(pid, result, meta) do
      ref = Process.monitor(pid)
      send(pid, {:agent_done, result, [], meta})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    defp stream(worker_id, run_id) do
      {:ok, events} =
        Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)

      events
    end

    test "completed claude run: one normalised UsageRecorded before WorkerExited", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      pid = start_worker(worker_id, run_id)
      deliver(pid, {:ok, "x"}, meta(usage: @claude_usage, events_cost_usd: 0.0123))

      events = stream(worker_id, run_id)
      assert Enum.map(events, & &1.event_type) == ["UsageRecorded", "WorkerExited"]

      [%{data: data}, _] = events

      assert %{
               "provider" => "claude",
               "model" => "opus",
               "project_id" => "proj-1",
               "task_id" => "task-1",
               "role" => "thread",
               "run_status" => "completed",
               "input_tokens" => 10,
               "output_tokens" => 5,
               "cache_read_tokens" => 100,
               "cache_write_tokens" => 20,
               "total_tokens" => 135,
               "cost_usd" => 0.0123
             } = data
    end

    test "a failed run still records its usage, with the failed status", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      pid = start_worker(worker_id, run_id)

      deliver(
        pid,
        {:error, :agent_failed},
        meta(run_status: :failed, usage: @claude_usage, events_cost_usd: nil)
      )

      assert [%{event_type: "UsageRecorded", data: data}, %{event_type: "WorkerExited"}] =
               stream(worker_id, run_id)

      assert data["run_status"] == "failed"
      assert data["total_tokens"] == 135
      assert data["cost_usd"] == nil
    end

    test "empty usage and nil cost record nothing", %{worker_id: worker_id, run_id: run_id} do
      pid = start_worker(worker_id, run_id)
      deliver(pid, {:ok, "x"}, meta(usage: %{}, events_cost_usd: nil))

      assert Enum.map(stream(worker_id, run_id), & &1.event_type) == ["WorkerExited"]
    end

    test "a session id and usage are both bound, in order, before WorkerExited", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      pid = start_worker(worker_id, run_id)

      deliver(
        pid,
        {:ok, "x"},
        meta(provider_session_id: "c0ffee", usage: @claude_usage, events_cost_usd: 0.1)
      )

      assert Enum.map(stream(worker_id, run_id), & &1.event_type) ==
               ["WorkerSessionBound", "UsageRecorded", "WorkerExited"]
    end
  end

  describe "run projection" do
    setup do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: "run-u", task_id: "t", project_id: "proj"}
          }
        ])
    end

    defp usage_event(worker_id, fields) do
      %{
        event_type: "UsageRecorded",
        payload:
          Map.merge(
            %{run_id: "run-u", worker_id: worker_id, provider: "claude", role: "thread"},
            fields
          )
      }
    end

    @phase_1 %{input_tokens: 10, output_tokens: 5, total_tokens: 15, cost_usd: 0.25}
    @phase_2 %{input_tokens: 7, output_tokens: 1, total_tokens: 8, cost_usd: 0.5}

    test "a run with no usage carries nil, not zeros" do
      assert %{usage: nil} = ProjectionStore.run("run-u")
    end

    test "two phases sum into run.usage and each worker keeps its own" do
      :ok =
        ProjectionStore.apply_events([usage_event("w1", @phase_1), usage_event("w2", @phase_2)])

      assert %{usage: usage, workers: workers} = ProjectionStore.run("run-u")

      assert %Usage{input_tokens: 17, output_tokens: 6, total_tokens: 23, cost_usd: 0.75} = usage
      assert %Usage{input_tokens: 10, cost_usd: 0.25} = workers["w1"].usage
      assert %Usage{input_tokens: 7, cost_usd: 0.5} = workers["w2"].usage
    end

    test "unknown cost stays nil when no phase reported one" do
      :ok = ProjectionStore.apply_events([usage_event("w1", %{input_tokens: 4})])

      assert %{usage: %Usage{input_tokens: 4, cost_usd: nil}} = ProjectionStore.run("run-u")
    end

    test "the fold is order-stable and replaying one worker's event is idempotent" do
      events = [usage_event("w1", @phase_1), usage_event("w2", @phase_2)]
      :ok = ProjectionStore.apply_events(events)
      forward = ProjectionStore.run("run-u").usage

      ProjectionStoreReset.reset!()

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: "run-u", task_id: "t", project_id: "proj"}
          }
          | Enum.reverse(events) ++ [hd(events)]
        ])

      assert ProjectionStore.run("run-u").usage == forward
    end

    test "a malformed payload leaves the projection untouched and does not raise" do
      before = ProjectionStore.run("run-u")

      malformed = %{event_type: "UsageRecorded", payload: %{run_id: "run-u"}}
      assert :ok = ProjectionStore.apply_events([malformed])
      assert ProjectionStore.run("run-u") == before
    end
  end
end
