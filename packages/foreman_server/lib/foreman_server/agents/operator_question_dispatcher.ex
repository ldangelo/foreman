defmodule ForemanServer.Agents.OperatorQuestionDispatcher do
  @moduledoc """
  Foreman-side dispatcher that converts a `com.foreman.operator.*`
  CloudEvent into the Foreman inbox pipeline (TRD-2026-4212be7e,
  JSI-T007 — paired with JSI-T006's subscriber).

  The dispatcher:
  1. Receives a Jido.Signal from `OperatorQuestionSubscriber.handle_info/2`.
  2. Calls `ForemanServer.Inbox.SharedInbox.ingest/2` with
     `OperatorQuestionSource` as the source module and the
     signal's `data` map as the payload.
  3. Returns the standard `SharedInbox.ingest/2` result:
     `{:ok, :started, _} | {:ok, :deduped, _} | {:error, reason}`.

  The `OperatorQuestionSource.correlation_id/1` function extracts
  the dedupe key (operator's `question_id`, falling back to
  `agent_id`). `SharedInbox.ingest/2` calls this to dedupe across
  retries.

  See also:
  - `ForemanServer.Agents.OperatorQuestionSubscriber` (JSI-T006 bus
    consumer)
  - `ForemanServer.Agents.OperatorQuestionSource` (correlation_id
    source module)
  - `ForemanServer.Agents.JidoSignalTopics.foreman_operator/0`
    (topic name source of truth)
  - `ForemanServer.Inbox.SharedInbox.ingest/2` (the downstream)
  """

  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Inbox.SharedInbox

  @doc """
  Dispatch a single `com.foreman.operator.*` CloudEvent to the
  Foreman inbox pipeline via `SharedInbox.ingest/2`.

  Returns the standard `SharedInbox.ingest/2` result.
  """
  @spec dispatch(struct() | map()) ::
          {:ok, :started, any()} | {:ok, :deduped, any()} | {:error, term()}
  def dispatch(%Jido.Signal{data: data}) when is_map(data) do
    SharedInbox.ingest(OperatorQuestionSource, data)
  end

  def dispatch(%{} = data) do
    SharedInbox.ingest(OperatorQuestionSource, data)
  end

  def dispatch(other) do
    {:error, {:invalid_payload, other}}
  end
end
