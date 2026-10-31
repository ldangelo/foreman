# Prints the events that carry the life of the named operator questions, one JSON object per line prefixed `QEV `:
#
#     QEV {"n":412,"stream":"question:run-1:q-1","at":"...","type":"QuestionAnswered","question_id":"q-1","text_length":7960,"text_sha256":"..."}
#
# Evaluated ON THE SERVER NODE by `rpc` (scripts/e2e/claude_projects/lib.sh); binding: question_ids (a list of question ids).
# What is printed: the question's own events (QuestionOpened, QuestionAnswered, QuestionExpired, QuestionAnswerUndelivered), and, in
# the asking run's stream, the run.steer events whose message id is `question:<id>` (RunSteerQueued, RunSteerDelivered,
# RunSteerConsumed, RunSteerUndelivered). An answer's TEXT is never printed: its length in characters (String.length, the
# aggregate's own unit) and its SHA-256 are, so a 8000-character steer can be compared byte for byte with what the harness sent
# without the event store dump's 4000-character cut. Read-only.
field = fn data, key ->
  data = if is_struct(data), do: Map.from_struct(data), else: data

  case data do
    %{} -> Map.get(data, key, Map.get(data, Atom.to_string(key)))
    _ -> nil
  end
end

ids = MapSet.new(question_ids)
steer_ids = MapSet.new(question_ids, &("question:" <> &1))
question_types = ~w(QuestionOpened QuestionAnswered QuestionExpired QuestionAnswerUndelivered)
steer_types = ~w(RunSteerQueued RunSteerDelivered)
steer_list_types = ~w(RunSteerConsumed RunSteerUndelivered)

relevant? = fn type, data ->
  cond do
    type in question_types -> MapSet.member?(ids, field.(data, :question_id))
    type in steer_types -> MapSet.member?(steer_ids, field.(data, :message_id))
    type in steer_list_types -> Enum.any?(List.wrap(field.(data, :message_ids)), &MapSet.member?(steer_ids, &1))
    true -> false
  end
end

text_info = fn data ->
  case field.(data, :text) do
    text when is_binary(text) ->
      %{
        text_length: String.length(text),
        text_bytes: byte_size(text),
        text_sha256: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      }

    _ ->
      %{}
  end
end

ForemanServer.EventStore.stream_all_forward(0, read_batch_size: 1_000)
|> Enum.each(fn event ->
  data = event.data

  if relevant?.(event.event_type, data) do
    record =
      %{
        n: event.event_number,
        stream: event.stream_uuid,
        at: DateTime.to_iso8601(event.created_at),
        type: event.event_type,
        question_id: field.(data, :question_id),
        run_id: field.(data, :run_id),
        project_id: field.(data, :project_id),
        agent_id: field.(data, :agent_id),
        answered_by: field.(data, :answered_by),
        steered_by: field.(data, :steered_by),
        message_id: field.(data, :message_id),
        message_ids: field.(data, :message_ids),
        mode: field.(data, :mode),
        delivery: field.(data, :delivery),
        reason: field.(data, :reason)
      }
      |> Map.merge(text_info.(data))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    IO.puts("QEV " <> Jason.encode!(record))
  end
end)

:ok
