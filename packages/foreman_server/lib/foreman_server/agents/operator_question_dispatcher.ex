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
    3. On `:started`, resolves the per-workflow operator timeout from
       the workflow manifest (TRD-027) and schedules it via
       `OperatorTimeout.schedule/3`.
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
  - `ForemanServer.Workflow.Catalog` (workflow manifest lookup)
  """

  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Agents.OperatorTimeout
  alias ForemanServer.Inbox.SharedInbox
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.Catalog

  # 5 minutes
  @operator_timeout_ms_default 5 * 60 * 1000

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
        question_id =
          data |> Map.get("question_id") |> non_empty() ||
            data |> Map.get(:question_id) |> non_empty()

        agent_id =
          data |> Map.get("agent_id") |> non_empty() ||
            data |> Map.get(:agent_id) |> non_empty()

        if question_id && agent_id do
          timeout_ms = resolve_operator_timeout(agent_id)
          _ = OperatorTimeout.schedule(question_id, agent_id, timeout_ms)
        end

        result

      other ->
        other
    end
  end

  def dispatch(other) do
    {:error, {:invalid_payload, other}}
  end

  # Resolve operator_timeout_ms from the workflow manifest, falling back to the
  # default.  The lookup chain is: task_id → task projection → workflow_snapshot
  # → workflow_name → Catalog manifest → "operator_timeout_ms" field.
  @spec resolve_operator_timeout(String.t()) :: pos_integer()
  defp resolve_operator_timeout(task_id) do
    with %{workflow_snapshot: snapshot} when is_map(snapshot) <-
           ProjectionStore.task_projection(task_id),
         workflow_name when is_binary(workflow_name) <-
           Map.get(snapshot, "workflow_name") || Map.get(snapshot, :workflow_name),
         {:ok, manifest} <- Catalog.load(workflow_name <> ".yaml"),
         timeout when is_integer(timeout) and timeout > 0 <-
           Map.get(manifest, "operator_timeout_ms") ||
             Map.get(manifest, :operator_timeout_ms) do
      timeout
    else
      _ -> @operator_timeout_ms_default
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(v), do: v
end
