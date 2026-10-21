defmodule ForemanServer.Coordinator.ReportFormatter do
  @moduledoc """
  Pure formatting of a thread report for the coordinator conversation: one
  bounded plain-text paragraph (verdict, scores, gap count, PR url, failure
  reason). Secrets are redacted when the text is appended
  (`Coordinator.Commands.append/4`), and the coordinator prompt renders reports
  inside an untrusted block, because verdict summaries quote model and bead text.
  """

  @max_bytes 1_500

  @type subject :: %{
          optional(:title) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:reason) => String.t() | nil
        }

  @spec format(String.t(), subject(), map()) :: String.t()
  def format("ReviewRecorded", subject, review) do
    scores =
      case Map.get(review, :scores) do
        %{} = scores when map_size(scores) > 0 ->
          " (" <> Enum.map_join(Enum.sort(scores), ", ", fn {k, v} -> "#{k} #{v}" end) <> ")"

        _ ->
          ""
      end

    gaps =
      case Map.get(review, :gap_bead_ids) do
        [_ | _] = ids -> " #{length(ids)} gap bead(s) filed."
        _ -> ""
      end

    [
      "#{label(subject)}: review verdict #{String.upcase(to_string(review.verdict))}#{scores}.#{gaps}",
      pr(subject),
      summary(Map.get(review, :summary))
    ]
    |> join()
  end

  def format(event_type, subject, _data) when event_type in ~w(RunCompleted JobsiteCompleted),
    do: join(["#{label(subject)}: finished.", pr(subject)])

  def format(event_type, subject, _data) when event_type in ~w(RunFailed JobsiteFailed),
    do: join(["#{label(subject)}: failed.", reason(subject)])

  def format(event_type, subject, _data) when event_type in ~w(RunCancelled JobsiteCancelled),
    do: join(["#{label(subject)}: was cancelled."])

  def format(event_type, subject, _data), do: join(["#{label(subject)}: #{event_type}."])

  defp label(subject) do
    title = subject |> Map.get(:title) |> one_line()
    id = Map.get(subject, :thread_id)
    Enum.join(Enum.reject(["Thread", id, title && "\"#{title}\""], &is_nil/1), " ")
  end

  defp pr(%{pr_url: url}) when is_binary(url) and url != "", do: "PR: #{url}"
  defp pr(_), do: nil

  defp reason(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "Reason: " <> one_line(reason)

  defp reason(_), do: nil

  defp summary(text) when is_binary(text) and text != "", do: "Summary: " <> one_line(text)
  defp summary(_), do: nil

  defp one_line(nil), do: nil
  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp join(parts) do
    text = parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if byte_size(text) > @max_bytes,
      do: String.slice(text, 0, @max_bytes) <> " [truncated]",
      else: text
  end
end
