defmodule ForemanServer.Coordinator.ActionSourceTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.{ActionSource, Error, Turn}

  defp block(json), do: "Thinking about it.\n\n```json\n" <> json <> "\n```\n"

  test "parses the reply and raw actions of the last json block" do
    text =
      block(~s({"reply": "first", "actions": []})) <>
        "\nOn reflection:\n" <>
        block(~s({"reply": " Done. ", "actions": [{"kind": "answer", "text": "x"}]}))

    assert {:ok, %Turn{reply: "Done.", actions: [%{"kind" => "answer", "text" => "x"}]}} =
             ActionSource.parse(text)
  end

  test "actions default to none" do
    assert {:ok, %Turn{reply: "hi", actions: []}} = ActionSource.parse(block(~s({"reply": "hi"})))
  end

  test "an unknown action kind is NOT a parse failure: it is left for the normaliser to reject and record" do
    assert {:ok, %Turn{actions: [%{"kind" => "merge_approve"}]}} =
             ActionSource.parse(
               block(~s({"reply": "ok", "actions": [{"kind": "merge_approve"}]}))
             )
  end

  test "everything else is malformed output and yields no turn" do
    bad = [
      "no block at all",
      "```json\n{not json}\n```",
      block("[1, 2]"),
      block(~s("just a string")),
      block(~s({"actions": []})),
      block(~s({"reply": "  ", "actions": []})),
      block(~s({"reply": 5})),
      block(~s({"reply": "x", "actions": "none"})),
      block(~s({"reply": "x", "actions": [1]})),
      block(~s({"reply": "x", "actions": [], "thoughts": "extra key"})),
      "```\n{\"reply\": \"x\"}\n```"
    ]

    for text <- bad do
      assert {:error, %Error{code: :malformed_output}} = ActionSource.parse(text),
             "accepted: #{inspect(text)}"
    end

    assert {:error, %Error{code: :malformed_output}} = ActionSource.parse(nil)
  end
end
