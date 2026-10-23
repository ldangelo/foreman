defmodule ForemanServer.Aggregates.RunSteerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventCodec

  defp apply_spec(state, %{event_type: type, payload: payload}),
    do: Run.apply_event(state, %{event_type: type, payload: payload})

  defp running_run(run_id \\ "run-steer-1") do
    Run.initial_state()
    |> Run.apply_event(%{
      event_type: "RunStarted",
      payload: %{run_id: run_id, task_id: "t", project_id: "p"}
    })
    |> Run.apply_event(%{event_type: "WorkerStarted", payload: %{run_id: run_id, worker_id: "w"}})
  end

  defp steer(state, attrs) do
    payload = Map.merge(%{run_id: "run-steer-1", message_id: "m1", text: "use tabs"}, attrs)
    Run.handle_command(state, %{type: "run.steer", payload: payload})
  end

  describe "run.steer" do
    test "queues the text on an in-progress run and projects it into pending_steer" do
      state = running_run()
      assert state.status == "in_progress"

      assert {:ok, spec} = steer(state, %{steered_by: "alice"})
      assert spec.event_type == "RunSteerQueued"
      assert spec.stream_id == "run:run-steer-1"

      assert %{message_id: "m1", text: "use tabs", steered_by: "alice", resume: true} =
               spec.payload

      state = apply_spec(state, spec)
      assert [%{message_id: "m1", text: "use tabs", resume: true}] = state.pending_steer
    end

    test "same message_id again is an idempotent no-op, even after it was consumed" do
      state = running_run()
      {:ok, spec} = steer(state, %{})
      state = apply_spec(state, spec)
      assert {:ok, nil} = steer(state, %{})

      {:ok, consume} =
        Run.handle_command(state, %{
          type: "run.steer.consume",
          payload: %{run_id: "run-steer-1", message_ids: ["m1"]}
        })

      state = apply_spec(state, consume)
      assert state.pending_steer == []
      assert {:ok, nil} = steer(state, %{})
    end

    test "empty or missing text is missing_or_invalid" do
      state = running_run()
      assert {:error, {:missing_or_invalid, :text}} = steer(state, %{text: ""})
      assert {:error, {:missing_or_invalid, :text}} = steer(state, %{text: nil})
      assert {:error, {:missing_or_invalid, :message_id}} = steer(state, %{message_id: ""})
    end

    test "8000 chars are accepted, 8001 are rejected with the length" do
      state = running_run()
      assert {:ok, _} = steer(state, %{text: String.duplicate("a", 8000)})

      assert {:error, {:text_too_long, 8001}} =
               steer(state, %{text: String.duplicate("a", 8001)})
    end

    test "a completed run rejects steering with run_terminal" do
      state =
        apply_spec(running_run(), %{
          event_type: "RunCompleted",
          payload: %{run_id: "run-steer-1"}
        })

      assert {:error, {:run_terminal, "completed"}} = steer(state, %{})
    end

    test "unknown run is not_found" do
      assert {:error, {:not_found, :run, "run-steer-1"}} = steer(Run.initial_state(), %{})
    end

    test "resume flag must be boolean and is carried on the event" do
      state = running_run()
      assert {:ok, %{payload: %{resume: false}}} = steer(state, %{resume: false})
      assert {:error, {:missing_or_invalid, :resume}} = steer(state, %{resume: "no"})
    end
  end

  describe "run.steer.consume" do
    test "removes only the listed ids from pending_steer, in order" do
      state =
        Enum.reduce(["m1", "m2", "m3"], running_run(), fn id, acc ->
          {:ok, spec} = steer(acc, %{message_id: id, text: "text #{id}"})
          apply_spec(acc, spec)
        end)

      {:ok, consume} =
        Run.handle_command(state, %{
          type: "run.steer.consume",
          payload: %{run_id: "run-steer-1", message_ids: ["m1", "m3"]}
        })

      assert consume.event_type == "RunSteerConsumed"
      state = apply_spec(state, consume)
      assert [%{message_id: "m2"}] = state.pending_steer
    end

    test "ids that are not pending are a no-op" do
      assert {:ok, nil} =
               Run.handle_command(running_run(), %{
                 type: "run.steer.consume",
                 payload: %{run_id: "run-steer-1", message_ids: ["ghost"]}
               })
    end

    test "message_ids must be a non-empty list of binaries" do
      for bad <- [nil, [], [1], "m1"] do
        assert {:error, {:missing_or_invalid, :message_ids}} =
                 Run.handle_command(running_run(), %{
                   type: "run.steer.consume",
                   payload: %{run_id: "run-steer-1", message_ids: bad}
                 })
      end
    end
  end

  describe "live delivery state" do
    defp cmd(state, type, payload) do
      Run.handle_command(state, %{type: type, payload: Map.put(payload, :run_id, "run-steer-1")})
    end

    defp queued(attrs \\ %{}) do
      state = running_run()
      {:ok, spec} = steer(state, attrs)
      apply_spec(state, spec)
    end

    test "deliver marks the pending message delivered but keeps it pending; repeat is a no-op" do
      state = queued()

      assert {:ok, %{event_type: "RunSteerDelivered", payload: %{mode: "live"}} = spec} =
               cmd(state, "run.steer.deliver", %{message_id: "m1"})

      state = apply_spec(state, spec)
      assert [%{message_id: "m1", delivered: true}] = state.pending_steer
      assert {:ok, nil} = cmd(state, "run.steer.deliver", %{message_id: "m1"})
      assert {:ok, nil} = cmd(state, "run.steer.deliver", %{message_id: "ghost"})
    end

    test "deliver is refused on a terminal run and rejects an unknown mode" do
      state = queued()

      assert {:error, {:missing_or_invalid, :delivery}} =
               cmd(state, "run.steer.deliver", %{message_id: "m1", mode: "carrier-pigeon"})

      {:ok, cancel} = cmd(state, "run.cancel", %{})
      terminal = apply_spec(state, cancel)

      assert {:error, {:run_terminal, _}} =
               cmd(terminal, "run.steer.deliver", %{message_id: "m1"})
    end

    test "consume records how the message was taken" do
      state = queued()

      assert {:ok, %{payload: %{delivery: "prompt"}}} =
               cmd(state, "run.steer.consume", %{message_ids: ["m1"]})

      assert {:ok, %{payload: %{delivery: "live"}}} =
               cmd(state, "run.steer.consume", %{message_ids: ["m1"], delivery: "live"})

      assert {:error, {:missing_or_invalid, :delivery}} =
               cmd(state, "run.steer.consume", %{message_ids: ["m1"], delivery: "x"})
    end

    test "undeliver retires pending messages, is accepted on a terminal run, and ignores non-pending ids" do
      state = queued()
      {:ok, cancel} = cmd(state, "run.cancel", %{})
      terminal = apply_spec(state, cancel)

      assert {:ok,
              %{
                event_type: "RunSteerUndelivered",
                payload: %{message_ids: ["m1"], reason: "run_cancelled"}
              } = spec} =
               cmd(terminal, "run.steer.undeliver", %{
                 message_ids: ["m1", "ghost"],
                 reason: "run_cancelled"
               })

      assert [] = apply_spec(terminal, spec).pending_steer

      assert {:ok, nil} =
               cmd(terminal, "run.steer.undeliver", %{message_ids: ["ghost"], reason: "x"})

      assert {:error, {:missing_or_invalid, :reason}} =
               cmd(terminal, "run.steer.undeliver", %{message_ids: ["m1"]})
    end

    test "new events are registered, decode to structs, and the old consumed shape still decodes" do
      assert %ForemanServer.Events.RunSteerDelivered{mode: "live"} =
               EventCodec.decode!("RunSteerDelivered", %{
                 run_id: "r",
                 message_id: "m",
                 mode: "live"
               })

      assert %ForemanServer.Events.RunSteerUndelivered{reason: "run_failed"} =
               EventCodec.decode!("RunSteerUndelivered", %{
                 run_id: "r",
                 message_ids: ["m"],
                 reason: "run_failed"
               })

      assert %ForemanServer.Events.RunSteerConsumed{delivery: nil} =
               EventCodec.decode!("RunSteerConsumed", %{run_id: "r", message_ids: ["m"]})
    end
  end

  describe "typed events and replay" do
    test "events are registered and decode to structs" do
      assert "RunSteerQueued" in EventCodec.registered()
      assert "RunSteerConsumed" in EventCodec.registered()

      assert %ForemanServer.Events.RunSteerQueued{resume: true, steered_by: nil} =
               EventCodec.decode!("RunSteerQueued", %{run_id: "r", message_id: "m", text: "t"})

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunSteerConsumed", %{run_id: "r"})
      end
    end

    test "a pre-steering stream (no steer events) replays without error and has no pending steering" do
      events = [
        %{event_type: "RunStarted", payload: %{run_id: "old", task_id: "t", project_id: "p"}},
        %{event_type: "WorkerStarted", payload: %{run_id: "old", worker_id: "w"}},
        %{event_type: "RunPaused", payload: %{run_id: "old", reason: "operator"}},
        %{event_type: "RunResumed", payload: %{run_id: "old"}},
        %{event_type: "RunCompleted", payload: %{run_id: "old"}}
      ]

      state = Enum.reduce(events, Run.initial_state(), &Run.apply_event(&2, &1))
      assert state.status == "completed"
      assert state.pending_steer == []
    end
  end
end
