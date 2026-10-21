defmodule ForemanServer.Aggregates.ThreadTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Thread
  alias ForemanServer.Aggregates.Thread.State
  alias ForemanServer.CommandRouter
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{ThreadReopened, ThreadResolved}

  @thread_id "run:r-1"

  defp resolve(payload, state \\ Thread.initial_state()) do
    base = %{thread_id: @thread_id, project_id: "p", at: "2026-10-20T00:00:00Z"}
    Thread.handle_command(state, %{type: "thread.resolve", payload: Map.merge(base, payload)})
  end

  defp reopen(payload \\ %{}, state) do
    base = %{thread_id: @thread_id, project_id: "p", at: "2026-10-21T00:00:00Z"}
    Thread.handle_command(state, %{type: "thread.reopen", payload: Map.merge(base, payload)})
  end

  defp resolved_state do
    {:ok, %{payload: payload}} = resolve(%{reason: "done"})
    Thread.apply_event(Thread.initial_state(), struct!(ThreadResolved, payload))
  end

  test "resolve emits ThreadResolved on the thread stream with every field" do
    assert {:ok, spec} =
             resolve(%{reason: "shipped", resolved_by: "op", source: "operator"})

    assert spec.stream_id == "thread:run:r-1"
    assert spec.event_type == "ThreadResolved"

    assert spec.payload == %{
             thread_id: @thread_id,
             project_id: "p",
             reason: "shipped",
             resolved_by: "op",
             source: "operator",
             at: "2026-10-20T00:00:00Z"
           }
  end

  test "resolve stamps `at` when absent and reason defaults to nil" do
    {:ok, spec} =
      Thread.handle_command(Thread.initial_state(), %{
        type: "thread.resolve",
        payload: %{thread_id: @thread_id, project_id: "p"}
      })

    assert spec.payload.reason == nil
    assert {:ok, _, _} = DateTime.from_iso8601(spec.payload.at)
  end

  test "resolving an already resolved thread is an idempotent no-op" do
    assert %State{resolved: true} = state = resolved_state()
    assert {:ok, nil} = resolve(%{}, state)
  end

  test "an already resolved thread still rejects an invalid command" do
    state = resolved_state()

    assert {:error, {:reason_too_long, 501}} =
             resolve(%{reason: String.duplicate("x", 501)}, state)

    assert {:error, {:missing_or_invalid, :project_id}} = resolve(%{project_id: ""}, state)
  end

  test "reason longer than 500 chars is a distinct error; exactly 500 is accepted" do
    assert {:error, {:reason_too_long, 501}} = resolve(%{reason: String.duplicate("x", 501)})
    assert {:ok, _} = resolve(%{reason: String.duplicate("x", 500)})
    assert {:error, {:missing_or_invalid, :reason}} = resolve(%{reason: 5})
  end

  test "missing or non-binary ids are distinct errors" do
    assert {:error, {:missing_or_invalid, :thread_id}} = resolve(%{thread_id: ""})
    assert {:error, {:missing_or_invalid, :thread_id}} = resolve(%{thread_id: nil})
    assert {:error, {:missing_or_invalid, :project_id}} = resolve(%{project_id: nil})
    assert {:error, {:missing_or_invalid, :resolved_by}} = resolve(%{resolved_by: 1})
    assert {:error, {:missing_or_invalid, :source}} = resolve(%{source: 1})
  end

  test "reopen when not resolved is a typed error carrying the thread id" do
    assert {:error, {:thread_not_resolved, @thread_id}} = reopen(Thread.initial_state())
  end

  test "reopen a resolved thread emits ThreadReopened; reopen twice errors again" do
    state = resolved_state()
    assert {:ok, spec} = reopen(%{reopened_by: "op", source: "operator"}, state)
    assert spec.stream_id == "thread:run:r-1"
    assert spec.event_type == "ThreadReopened"

    assert spec.payload == %{
             thread_id: @thread_id,
             project_id: "p",
             reopened_by: "op",
             source: "operator",
             at: "2026-10-21T00:00:00Z"
           }

    reopened = Thread.apply_event(state, struct!(ThreadReopened, spec.payload))
    assert %State{resolved: false, resolved_at: nil, reason: nil} = reopened
    assert {:error, {:thread_not_resolved, @thread_id}} = reopen(reopened)
  end

  test "apply_event handles typed, decoded and unknown events (catch-all leaves state)" do
    {:ok, spec} = resolve(%{reason: "r"})
    s0 = Thread.initial_state()

    typed = Thread.apply_event(s0, struct!(ThreadResolved, spec.payload))
    assert %State{resolved: true, resolved_at: "2026-10-20T00:00:00Z", reason: "r"} = typed

    decoded = Thread.apply_event(s0, %{event_type: "ThreadResolved", payload: spec.payload})
    assert decoded == typed

    assert typed == Thread.apply_event(typed, %{event_type: "SomethingElse", payload: %{}})
    assert typed == Thread.apply_event(typed, %{unrelated: true})
  end

  test "unrelated commands are unhandled" do
    assert :unhandled =
             Thread.handle_command(Thread.initial_state(), %{type: "nope", payload: %{}})
  end

  test "EventCodec registers both events and CommandRouter routes the prefix" do
    assert "ThreadResolved" in EventCodec.registered()
    assert "ThreadReopened" in EventCodec.registered()
    assert CommandRouter.aggregate_module_for("thread:run:r-1") == Thread
    assert CommandRouter.aggregate_module_for("thread:jobsite:j-1") == Thread
  end
end
