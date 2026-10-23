defmodule ForemanServer.Aggregates.ReviewTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Review
  alias ForemanServer.Aggregates.Review.State
  alias ForemanServer.{CommandGateway, EventCodec, EventStore, ProjectionStore}
  alias ForemanServer.Events.ReviewRecorded

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        subject_kind: "run",
        subject_id: "run-#{uuid()}",
        project_id: "proj-1",
        bead_id: "foreman-abc",
        verdict: "partially_met",
        scores: %{"correctness" => 4, "tests" => 2, "documentation" => 3, "robustness" => 3},
        summary: "Tests are thin.",
        gap_bead_ids: ["foreman-g1"],
        archive_path: "/tmp/archive",
        analysis_path: "/tmp/archive/analysis.json",
        evaluator: "agent:claude",
        at: "2026-10-20T00:00:00Z"
      },
      overrides
    )
  end

  defp handle(p, state \\ Review.initial_state()),
    do: Review.handle_command(state, %{type: "review.record", payload: p})

  test "emits exactly one ReviewRecorded on the per-subject stream with all fields" do
    p =
      payload(%{
        subject_kind: "jobsite",
        subject_id: "js-1",
        model: "m1",
        usage: %{"input_tokens" => 5},
        usage_provider: "claude"
      })

    assert {:ok, spec} = handle(p)
    assert spec.stream_id == "review:jobsite:js-1"
    assert spec.event_type == "ReviewRecorded"

    assert spec.payload == %{
             subject_kind: "jobsite",
             subject_id: "js-1",
             project_id: "proj-1",
             bead_id: "foreman-abc",
             verdict: "partially_met",
             scores: p.scores,
             summary: "Tests are thin.",
             gap_bead_ids: ["foreman-g1"],
             archive_path: "/tmp/archive",
             analysis_path: "/tmp/archive/analysis.json",
             evaluator: "agent:claude",
             error_code: nil,
             model: "m1",
             usage: %{"input_tokens" => 5},
             usage_provider: "claude",
             at: "2026-10-20T00:00:00Z"
           }
  end

  test "optional fields default to nil / empty and `at` is stamped" do
    p =
      payload()
      |> Map.drop([:bead_id, :scores, :gap_bead_ids, :archive_path, :analysis_path, :evaluator])

    assert {:ok, %{payload: out}} = handle(Map.delete(p, :at))
    assert out.bead_id == nil and out.scores == nil and out.gap_bead_ids == []
    assert {:ok, _, _} = DateTime.from_iso8601(out.at)
  end

  test "invalid subject_kind and missing subject_kind are distinct errors" do
    assert {:error, {:invalid_subject_kind, "bead"}} = handle(payload(%{subject_kind: "bead"}))
    assert {:error, {:missing_or_invalid, :subject_kind}} = handle(payload(%{subject_kind: nil}))
    assert {:error, {:missing_or_invalid, :subject_kind}} = handle(payload(%{subject_kind: ""}))
  end

  test "invalid verdict and missing verdict are distinct errors" do
    assert {:error, {:invalid_verdict, "great"}} = handle(payload(%{verdict: "great"}))
    assert {:error, {:missing_or_invalid, :verdict}} = handle(payload(%{verdict: nil}))
  end

  test "required fields and field shapes are validated" do
    assert {:error, {:missing_or_invalid, :subject_id}} = handle(payload(%{subject_id: ""}))
    assert {:error, {:missing_or_invalid, :project_id}} = handle(payload(%{project_id: ""}))
    assert {:ok, %{payload: %{project_id: nil}}} = handle(payload(%{project_id: nil}))
    assert {:error, {:missing_or_invalid, :summary}} = handle(payload(%{summary: nil}))
    assert {:error, {:missing_or_invalid, :bead_id}} = handle(payload(%{bead_id: ""}))
    assert {:error, {:missing_or_invalid, :scores}} = handle(payload(%{scores: "high"}))

    assert {:error, {:missing_or_invalid, :gap_bead_ids}} =
             handle(payload(%{gap_bead_ids: ["ok", ""]}))
  end

  test "a different command for an already-reviewed subject is rejected" do
    p = payload()
    {:ok, spec} = handle(p)
    state = Review.apply_event(Review.initial_state(), struct!(ReviewRecorded, spec.payload))

    assert %State{recorded: true, verdict: "partially_met"} = state
    assert {:error, {:already_recorded, "run", id}} = handle(p, state)
    assert id == p.subject_id
  end

  # foreman-uxfwb: an `undetermined` review (the reviewer failed, not the work) must be
  # re-runnable; any real verdict stays final.
  test "an undetermined review may be superseded, and only an undetermined one" do
    {:ok, undetermined} =
      handle(payload(%{verdict: "undetermined", error_code: "evaluator_failed"}))

    state =
      Review.apply_event(Review.initial_state(), struct!(ReviewRecorded, undetermined.payload))

    assert %State{recorded: true, verdict: "undetermined"} = state

    p = payload(%{subject_id: undetermined.payload.subject_id, verdict: "met"})
    assert {:ok, %{event_type: "ReviewRecorded"} = met} = handle(p, state)

    # A second failure may be superseded again; a real verdict is final.
    again = Review.apply_event(state, struct!(ReviewRecorded, undetermined.payload))
    assert {:ok, _} = handle(p, again)

    final = Review.apply_event(state, struct!(ReviewRecorded, met.payload))
    assert %State{recorded: true, verdict: "met"} = final
    assert {:error, {:already_recorded, "run", _id}} = handle(p, final)
  end

  test "apply_event handles typed, decoded and unknown events" do
    {:ok, spec} = handle(payload(%{verdict: "not_met"}))
    s0 = Review.initial_state()
    assert %State{recorded: false, verdict: nil} = s0

    typed = Review.apply_event(s0, struct!(ReviewRecorded, spec.payload))
    assert %State{recorded: true, verdict: "not_met"} = typed

    decoded =
      Review.apply_event(s0, %{event_type: "ReviewRecorded", payload: spec.payload})

    assert decoded == typed

    assert typed == Review.apply_event(typed, %{event_type: "SomethingElse", payload: %{}})
  end

  test "unrelated commands are unhandled" do
    assert :unhandled =
             Review.handle_command(Review.initial_state(), %{type: "nope", payload: %{}})
  end

  test "EventCodec registers the event and CommandRouter routes the prefix" do
    assert "ReviewRecorded" in EventCodec.registered()
    assert ForemanServer.CommandRouter.aggregate_module_for("review:run:r1") == Review
  end

  describe "dispatch through CommandGateway.dispatch_system/2" do
    defp command(p) do
      %{
        aggregate_id: Review.stream_id(p.subject_kind, p.subject_id),
        type: "review.record",
        command_id: "review:#{p.subject_kind}:#{p.subject_id}",
        payload: p
      }
    end

    defp await_review(kind, id, tries \\ 50) do
      case ProjectionStore.review(kind, id) do
        nil when tries > 0 ->
          Process.sleep(20)
          await_review(kind, id, tries - 1)

        other ->
          other
      end
    end

    test "records once, projects the verdict, and a duplicate appends nothing" do
      p = payload()
      cmd = command(p)

      assert {:ok, _} = CommandGateway.dispatch_system(cmd)
      assert {:ok, _} = CommandGateway.dispatch_system(cmd)

      assert {:ok, [event]} =
               EventStore.read_stream_forward(Review.stream_id("run", p.subject_id), 0, 99_999)

      assert event.event_type == "ReviewRecorded"

      review = await_review("run", p.subject_id)
      assert review.verdict == "partially_met"
      assert review.bead_id == "foreman-abc"
      assert review.gap_bead_ids == ["foreman-g1"]
      assert review.project_id == "proj-1"
      assert ProjectionStore.review("jobsite", p.subject_id) == nil
    end

    test "an invalid command appends nothing and projects nothing" do
      p = payload(%{verdict: "great"})

      assert {:error, _} = CommandGateway.dispatch_system(command(p))

      assert {:error, :stream_not_found} =
               EventStore.read_stream_forward(Review.stream_id("run", p.subject_id), 0, 99_999)

      assert ProjectionStore.review("run", p.subject_id) == nil
    end

    test "is not on the operator allowlist" do
      p = payload()

      assert {:error, {:command_not_allowed, "review.record"}} =
               CommandGateway.dispatch_operator(Map.put(command(p), :command_id, "op-#{uuid()}"))
    end

    test "an undetermined review is superseded by a record under a new command id only" do
      p = payload(%{verdict: "undetermined", error_code: "evaluator_failed"})
      first = command(p)
      assert {:ok, _} = CommandGateway.dispatch_system(first)

      met = payload(%{subject_id: p.subject_id, verdict: "met", summary: "Re-run: met."})
      rerun = %{command(met) | command_id: first.command_id <> ":supersedes:" <> p.at}

      assert {:ok, _} = CommandGateway.dispatch_system(rerun)
      # The same re-run command again appends nothing.
      assert {:ok, _} = CommandGateway.dispatch_system(rerun)

      assert {:ok, [first_event, second_event]} =
               EventStore.read_stream_forward(Review.stream_id("run", p.subject_id), 0, 99_999)

      assert first_event.event_type == "ReviewRecorded"
      assert second_event.event_type == "ReviewRecorded"

      review = await_review_verdict("run", p.subject_id, "met")
      assert review.summary == "Re-run: met."

      # A real verdict is final: another command id is rejected.
      other = %{command(met) | command_id: "review:other-attempt-" <> uuid()}
      assert {:error, {:already_recorded, "run", _}} = CommandGateway.dispatch_system(other)
    end

    defp await_review_verdict(kind, id, verdict, tries \\ 100) do
      case ProjectionStore.review(kind, id) do
        %{verdict: ^verdict} = review ->
          review

        _other when tries > 0 ->
          Process.sleep(20)
          await_review_verdict(kind, id, verdict, tries - 1)

        other ->
          other
      end
    end
  end
end
