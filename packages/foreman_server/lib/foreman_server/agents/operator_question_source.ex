defmodule ForemanServer.Agents.OperatorQuestionSource do
  @moduledoc """
  The `ForemanServer.Inbox.SharedInbox.ingest/2` source module
  identifier for operator-question signals (TRD-2026-4212be7e, JSI-T007).

  `SharedInbox.ingest/2` requires a source module that exports
  `correlation_id/1`: given the operator question's data map, return
  the dedupe key. The correlation key is the operator's
  `question_id` (the unique identifier the operator UI assigned when
  the question was asked) — falling back to `agent_id` if the
  question_id is missing, then to `nil` if neither is present (which
  `SharedInbox.ingest/2` rejects with `:no_correlation_id`).

  This module exports a `correlation_id/1` function so it can be
  passed as the first argument to `SharedInbox.ingest/2`. The
  module is intentionally tiny — it's the source-side contract
  only. The full conversion of `signal.data` to the inbox shape
  lives in `ForemanServer.Agents.OperatorQuestionDispatcher`.
  """

  @doc """
  Extract the dedupe correlation_id from an operator question's
  data map.

  ## Returns

  - `question_id` (binary) when present
  - `agent_id` (binary) as a fallback when `question_id` is missing
  - `nil` when neither is present (caller will get
    `:no_correlation_id` from `SharedInbox.ingest/2`)
  """
  @spec correlation_id(map()) :: String.t() | nil
  def correlation_id(data) when is_map(data) do
    # Sequential Map.get with explicit fallback. Each step passes
    # through `non_empty/1` which treats nil and "" as missing — this
    # guards against Jido's data round-trip (atom keys → string keys)
    # and against operator signals where the field is present but empty.
    data
    |> Map.get("question_id", :__missing__)
    |> non_empty()
    |> fallback(Map.get(data, :question_id, :__missing__) |> non_empty())
    |> fallback(Map.get(data, "agent_id", :__missing__) |> non_empty())
    |> fallback(Map.get(data, :agent_id, :__missing__) |> non_empty())
  end

  def correlation_id(_), do: nil

  defp non_empty(:__missing__), do: nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value
  defp non_empty(value), do: value

  defp fallback(nil, next), do: next
  defp fallback(value, _), do: value
end
