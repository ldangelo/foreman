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
  3. On `:started`, schedules an operator timeout via
     `OperatorTimeout.schedule/3` using the question_id as the
     timeout key and agent_id as the task identifier.
  4. Returns the standard `SharedInbox.ingest/2` result.

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
  - `ForemanServer.Agents.OperatorTimeout` (JSI-T009 — timeout
    scheduling; call site here)
  """

  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Agents.OperatorTimeout
  alias ForemanServer.Inbox.SharedInbox

  @operator_timeout_ms 5 * 60 * 1000  # 5 minutes — matches OperatorTimeout.default
  @doc """
  Dispatch a single `com.foreman.operator.*` CloudEvent to the
  Foreman inbox pipeline via `SharedInbox.ingest/2`.

  On `:started`, schedules an operator timeout (JSI-T009).

  Returns the standard `SharedInbox.ingest/2` result.
  """
  @spec dispatch(struct() | map()) ::
          {:ok, :started, any()} | {:ok, :deduped, any()} | {:error, term()}
  def dispatch(%Jido.Signal{data: data}) when is_map(data) do
    dispatch(data)
  end

  def dispatch(%{} = data) do
    case SharedInbox.ingest(OperatorQuestionSource, data) do
      {:ok, :started, _item} = result ->
        # Schedule operator timeout (JSI-T009).
        # Keys are question_id (workflow) and agent_id (task) — the
        # operator question data carries these; the agent side should
        # include task_id to enable task.block on expiry. See
        # foreman-b8s.
        question_id = data |> Map.get("question_id") |> non_empty() ||
                         data |> Map.get(:question_id) |> non_empty()
        agent_id = data |> Map.get("agent_id") |> non_empty() ||
                       data |> Map.get(:agent_id) |> non_empty()

        if question_id && agent_id do
          _ = OperatorTimeout.schedule(question_id, agent_id, @operator_timeout_ms)
        end

        result

      other ->
        other
    end
  end

  def dispatch(other) do
    {:error, {:invalid_payload, other}}
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(v), do: v
end
