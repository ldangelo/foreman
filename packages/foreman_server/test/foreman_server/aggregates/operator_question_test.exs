defmodule ForemanServer.Aggregates.OperatorQuestionTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.OperatorQuestion, as: Q
  alias ForemanServer.Aggregates.Run
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

  test "a blank answer is refused" do
    open = fold(["question.open"])

    assert {:error, {:missing_or_invalid, :text}} =
             Q.handle_command(open, cmd("question.answer", %{text: " "}))
  end

  # An answer reaches the run that asked as a `run.steer` message (`Q.steer_text/2`: the answer
  # behind a prefix naming the question) and `run.steer` caps its text. The limit on an answer is
  # what that cap leaves after the prefix, so an answer is never accepted that could not be
  # delivered: 8000 characters used to be accepted here and refused by the steer, unseen.
  describe "the answer limit" do
    defp answer(state, question_id, text) do
      Q.handle_command(state, %{
        type: "question.answer",
        payload: %{run_id: "r1", question_id: question_id, text: text}
      })
    end

    test "the longest answer fills the steer cap exactly; one character more is refused naming the limit" do
      open = fold(["question.open"])
      limit = Run.steer_text_max_chars() - String.length("Answer to your question q1: ")

      assert {:ok, %{event_type: "QuestionAnswered", payload: %{text: text}}} =
               answer(open, "q1", String.duplicate("a", limit))

      assert String.length(Q.steer_text("q1", text)) == Run.steer_text_max_chars()

      assert {:error, {:answer_too_long, over, ^limit}} =
               answer(open, "q1", String.duplicate("a", limit + 1))

      assert over == limit + 1
    end

    for {label, question_id} <- [
          short: "q1",
          uuid: "q-6f1c2d9e-3b7a-4c58-9a10-2e8d5b7c4f31",
          multibyte: String.duplicate("日", 40),
          emoji: String.duplicate("👨‍👩‍👧‍👦", 10),
          very_long: String.duplicate("x", 3_000)
        ] do
      test "the limit for a #{label} question id is what the steer cap leaves after its prefix" do
        question_id = unquote(question_id)
        open = fold(["question.open"])
        limit = Run.steer_text_max_chars() - String.length(Q.steer_text(question_id, ""))
        assert limit > 0
        assert Q.max_answer_chars(question_id) == limit

        # multibyte on purpose: the limit counts characters, not bytes
        assert {:ok, %{payload: %{text: text}}} =
                 answer(open, question_id, String.duplicate("é", limit))

        assert String.length(Q.steer_text(question_id, text)) <= Run.steer_text_max_chars()

        assert {:error, {:answer_too_long, over, ^limit}} =
                 answer(open, question_id, String.duplicate("é", limit + 1))

        assert over == limit + 1
      end
    end

    test "a question id whose prefix alone fills the steer cap cannot be answered at all" do
      open = fold(["question.open"])
      question_id = String.duplicate("i", Run.steer_text_max_chars())

      assert Q.max_answer_chars(question_id) == 0
      assert {:error, {:answer_too_long, 1, 0}} = answer(open, question_id, "x")
    end
  end

  # `question_id` is agent-supplied and rides in the steer prefix; unbounded, an id of the steer
  # cap's length left a cap of 0, so every answer was refused and the UI rendered maxlength=0.
  describe "the question id bound" do
    defp open(question_id) do
      Q.handle_command(Q.initial_state(), %{
        type: "question.open",
        payload: %{run_id: "r1", question_id: question_id, text: "why?"}
      })
    end

    test "an id at the limit opens and stays answerable with a positive cap" do
      max = Q.max_question_id_chars()
      question_id = String.duplicate("日", max)

      assert {:ok, %{event_type: "QuestionOpened", payload: %{question_id: ^question_id}} = spec} =
               open(question_id)

      assert Q.max_answer_chars(question_id) > 0

      state =
        Q.apply_event(Q.initial_state(), %{event_type: "QuestionOpened", payload: spec.payload})

      assert {:ok, %{event_type: "QuestionAnswered"}} =
               answer(state, question_id, String.duplicate("a", Q.max_answer_chars(question_id)))
    end

    test "an id over the limit is refused naming the limit and records nothing" do
      max = Q.max_question_id_chars()

      assert {:error, {:question_id_too_long, over, ^max}} =
               open(String.duplicate("x", max + 1))

      assert over == max + 1

      assert {:error, {:question_id_too_long, _, ^max}} =
               open(String.duplicate("x", Run.steer_text_max_chars()))
    end
  end

  test "expire only from open" do
    assert {:ok, %{event_type: "QuestionExpired"}} =
             Q.handle_command(fold(["question.open"]), cmd("question.expire"))

    assert {:error, {:question_not_open, "answered"}} =
             Q.handle_command(fold(["question.open", "question.answer"]), cmd("question.expire"))
  end
end
