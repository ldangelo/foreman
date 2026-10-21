defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerSessionTest do
  @moduledoc """
  The workflow door used to throw the provider's own session id away:
  `RunResult.normalize/1` keeps only the text, so nothing could ever resume a
  workflow agent's thread. These tests pin that the id now survives into a
  `WorkerSessionBound` event on the worker stream, ahead of `WorkerExited`,
  and that a FAILED run keeps its id too (it is the one a fix thread resumes).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.{RunMeta, Tracker}

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp run_result(attrs) do
    struct!(
      %Jido.Harness.RunResult{run_id: "harness-run", provider: :claude, status: :completed},
      attrs
    )
  end

  describe "build_meta/2" do
    test "a failed run still yields its provider session id" do
      result = run_result(status: :failed, provider_session_id: "c0ffee", error: :boom)

      assert %RunMeta{provider: :claude, provider_session_id: "c0ffee", run_status: :failed} =
               JidoHarnessWorker.build_meta(:claude, result)
    end

    test "an absent or blank session id is nil, never an empty string" do
      assert %RunMeta{provider_session_id: nil} =
               JidoHarnessWorker.build_meta(:pi, run_result(provider_session_id: nil))

      assert %RunMeta{provider_session_id: nil} =
               JidoHarnessWorker.build_meta(:pi, run_result(provider_session_id: ""))
    end

    test "provider cost comes from the last run_completed event, nil when unreported" do
      completed = fn cost ->
        %Jido.Harness.Event{
          type: :run_completed,
          provider: :claude,
          payload: %{"cost_usd" => cost},
          timestamp: "2026-01-01T00:00:00Z"
        }
      end

      assert %RunMeta{events_cost_usd: 0.5} =
               JidoHarnessWorker.build_meta(
                 :claude,
                 run_result(events: [completed.(0.1), completed.(0.5)])
               )

      assert %RunMeta{events_cost_usd: nil} =
               JidoHarnessWorker.build_meta(:claude, run_result(events: [completed.(nil)]))

      assert %RunMeta{events_cost_usd: nil, usage: %{}} =
               JidoHarnessWorker.build_meta(:claude, run_result([]))
    end
  end

  describe "agent_done delivery" do
    setup do
      start_supervised!({Tracker, []}, id: :tracker)
      {:ok, worker_id: uuid(), run_id: uuid()}
    end

    defp start_worker(worker_id, run_id) do
      opts = [worker_id: worker_id, run_id: run_id, provider: :claude, prompt: "p"]

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

    defp event_types(worker_id, run_id) do
      {:ok, events} =
        Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)

      Enum.map(events, & &1.event_type)
    end

    test "binds the session id exactly once, before WorkerExited", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      pid = start_worker(worker_id, run_id)
      meta = %RunMeta{provider: :claude, provider_session_id: "c0ffee", run_status: :completed}

      deliver(pid, {:ok, "x"}, meta)

      assert event_types(worker_id, run_id) == ["WorkerSessionBound", "WorkerExited"]

      {:ok, [bound | _]} =
        Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)

      assert bound.data["provider"] == "claude"
      assert bound.data["provider_session_id"] == "c0ffee"
    end

    test "a failed run still binds its session id", %{worker_id: worker_id, run_id: run_id} do
      pid = start_worker(worker_id, run_id)
      meta = %RunMeta{provider: :claude, provider_session_id: "c0ffee", run_status: :failed}

      deliver(pid, {:error, :agent_failed}, meta)

      assert event_types(worker_id, run_id) == ["WorkerSessionBound", "WorkerExited"]
    end

    test "no session id (or no meta at all) emits nothing", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      pid = start_worker(worker_id, run_id)
      meta = %RunMeta{provider: :pi, provider_session_id: nil, run_status: :completed}
      deliver(pid, {:ok, "x"}, meta)
      assert event_types(worker_id, run_id) == ["WorkerExited"]

      other_worker = uuid()
      other_run = uuid()
      pid = start_worker(other_worker, other_run)
      deliver(pid, {:error, :provider_unavailable}, nil)
      assert event_types(other_worker, other_run) == ["WorkerExited"]
    end
  end
end
