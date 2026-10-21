defmodule ForemanServer.Aggregates.OperatorQuestionTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.OperatorQuestion, as: Q
  alias ForemanServer.CommandRouter

  @ids %{run_id: "r1", question_id: "q1"}

  defp cmd(type, extra \\ %{}), do: %{type: type, payload: Map.merge(@ids, extra)}

  defp fold(types) do
    Enum.reduce(types, Q.initial_state(), fn type, state ->
      {:ok, spec} = Q.handle_command(state, cmd(type, %{text: "t"}))

      if spec,
        do: Q.apply_event(state, %{event_type: spec.event_type, payload: spec.payload}),
        else: state
    end)
  end

  test "prefix routes here" do
    assert CommandRouter.aggregate_module_for(Q.stream_id("r", "q")) == Q
  end

  test "open, then open again is an idempotent no-op" do
    assert {:ok, %{event_type: "QuestionOpened"}} =
             Q.handle_command(Q.initial_state(), cmd("question.open", %{text: "why?"}))

    assert {:ok, nil} = Q.handle_command(fold(["question.open"]), cmd("question.open"))
  end

  test "answer needs an open question; double answer and answer after expiry are typed errors" do
    assert {:error, {:question_not_open, nil}} =
             Q.handle_command(Q.initial_state(), cmd("question.answer", %{text: "x"}))

    open = fold(["question.open"])

    assert {:ok, %{event_type: "QuestionAnswered"}} =
             Q.handle_command(open, cmd("question.answer", %{text: "yes"}))

    assert {:error, {:question_not_open, "answered"}} =
             Q.handle_command(
               fold(["question.open", "question.answer"]),
               cmd("question.answer", %{text: "again"})
             )

    assert {:error, {:question_not_open, "expired"}} =
             Q.handle_command(
               fold(["question.open", "question.expire"]),
               cmd("question.answer", %{text: "late"})
             )
  end

  test "answer text is validated with distinct errors" do
    open = fold(["question.open"])

    assert {:error, {:missing_or_invalid, :text}} =
             Q.handle_command(open, cmd("question.answer", %{text: " "}))

    assert {:error, {:text_too_long, 8001}} =
             Q.handle_command(open, cmd("question.answer", %{text: String.duplicate("a", 8001)}))
  end

  test "expire only from open" do
    assert {:ok, %{event_type: "QuestionExpired"}} =
             Q.handle_command(fold(["question.open"]), cmd("question.expire"))

    assert {:error, {:question_not_open, "answered"}} =
             Q.handle_command(fold(["question.open", "question.answer"]), cmd("question.expire"))
  end
end
