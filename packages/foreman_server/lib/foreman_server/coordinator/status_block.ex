defmodule ForemanServer.Coordinator.StatusBlock do
  @moduledoc """
  The authoritative thread-status line of a coordinator reply.

  A model summarising "how are my threads doing" does its own arithmetic over
  the thread cards and gets it wrong (live acceptance F7: "five ready for
  review" with two). The counts per Overview group are computed by
  `ForemanServer.Overview`; the server hands them to the model in the STATUS
  section of its context and, when a reply talks about thread status, appends
  this line to the stored reply so the operator always sees the true numbers
  next to whatever the model said. The JSON actions contract is untouched: only
  the reply text is annotated, never the actions.
  """

  alias ForemanServer.Overview.Group

  @type counts :: %{Group.group() => non_neg_integer()}

  @marker "Status (computed by Foreman from the Overview):"

  # A reply that speaks about thread states. Deliberately broad: a false
  # positive costs one extra line, a false negative leaves a wrong summary.
  @status_words ~r/\b(ready for review|waiting on you|working|landing|idle|resolved|in progress|status)\b/i

  @labels %{
    ready_for_review: "ready for review",
    waiting_on_you: "waiting on you",
    working: "working",
    landing: "landing",
    idle: "idle",
    resolved: "resolved"
  }

  @doc "`ready for review 2 · waiting on you 0 · ...` for every Overview group."
  @spec line(counts()) :: String.t()
  def line(counts) when counts == %{}, do: "(unavailable)"

  def line(counts) when is_map(counts) do
    Enum.map_join(Group.all(), " · ", fn group ->
      "#{Map.fetch!(@labels, group)} #{Map.get(counts, group, 0)}"
    end)
  end

  @doc """
  The reply with the authoritative status line appended when it talks about
  thread status. Replies that do not, empty counts, and replies that already
  carry the line are returned unchanged.
  """
  @spec annotate(String.t(), counts()) :: String.t()
  def annotate(reply, counts) when is_binary(reply) and counts == %{}, do: reply

  def annotate(reply, counts) when is_binary(reply) and is_map(counts) do
    if Regex.match?(@status_words, reply) and not String.contains?(reply, @marker) do
      String.trim_trailing(reply) <> "\n\n" <> @marker <> " " <> line(counts)
    else
      reply
    end
  end
end
