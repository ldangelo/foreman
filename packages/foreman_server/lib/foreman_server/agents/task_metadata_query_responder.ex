defmodule ForemanServer.Agents.TaskMetadataQueryResponder do
  @moduledoc """
  Foreman-side consumer of the task-metadata query signal
  (TRD-2026-4212be7e, JSI-T012).

  The Agent→Foreman query signal pattern is
  `com.foreman.query.task_metadata.<project>` (a Jido-aligned topic,
  sibling to the `com.foreman.command.*` and `agents.<id>.directive`
  topics defined in `ForemanServer.Agents.JidoSignalTopics`). The
  responder looks up the task via the configured `TaskProvider` and
  publishes a response signal back to the agent via
  `SignalDirectivePublisher.publish/3`.

  ## Two signal types

    1. **Query (Agent→Foreman)** —
       type: `com.foreman.query.task_metadata.<project>`
       data: `%{"task_id" => ..., "agent_id" => ..., "query_id" => ...}`

    2. **Response (Foreman→Agent)** —
       type: `agents.<agent_id>.directive`
       data: `%{"query_id" => ..., "metadata" => <task>}` on success
       data: `%{"query_id" => ..., "error" => <reason>}` on failure

  ## Wire shape only

  This module is the wire-shape layer: it builds query/response
  signals, validates the topic, and looks up the task via an
  injected provider function. The actual bus subscription, the
  full end-to-end flow (Agent publishes query → Foreman subscribes
  → Foreman publishes response → Agent receives), and the
  integration with the supervised bus land in JSI-T013.
  """

  @doc """
  Build the wire shape of a query signal (Agent→Foreman).

  ## Arguments

    - `project` — the Foreman project_id (used in the topic suffix).
    - `task_id` — the task to look up.
    - `agent_id` — the requesting agent (used in the response).
    - `query_id` — the unique query identifier (echoed in the response).

  ## Returns

  A `%Jido.Signal{}` struct (not yet published) with type
  `com.foreman.query.task_metadata.<project>` and the data fields
  described in the moduledoc.
  """
  @spec build_query(String.t(), String.t(), String.t(), String.t()) :: struct()
  def build_query(project, task_id, agent_id, query_id)
      when is_binary(project) and is_binary(task_id) and is_binary(agent_id) and is_binary(query_id) do
    {:ok, signal} =
      Jido.Signal.new(
        "com.foreman.query.task_metadata.#{project}",
        %{
          task_id: task_id,
          agent_id: agent_id,
          query_id: query_id
        },
        source: "foreman.task_metadata_query_responder"
      )

    signal
  end

  @doc """
  Build the wire shape of a response signal (Foreman→Agent).

  ## Arguments

    - `agent_id` — the agent to route the response to.
    - `query_id` — the query identifier to echo back.
    - `result` — the provider lookup result, either `{:ok, metadata}`
      or `{:error, reason}`.

  ## Returns

  A `%Jido.Signal{}` struct (not yet published) with type
  `agents.<agent_id>.directive` and the data fields described in
  the moduledoc. On success, `data.metadata` holds the task; on
  failure, `data.error` holds the reason.
  """
  @spec build_response(String.t(), String.t(), {:ok, term()} | {:error, term()}) :: struct()
  def build_response(agent_id, query_id, {:ok, metadata}) when is_binary(agent_id) do
    {:ok, signal} =
      Jido.Signal.new(
        "agents.#{agent_id}.directive",
        %{
          query_id: query_id,
          metadata: metadata
        },
        source: "foreman.task_metadata_query_responder"
      )

    signal
  end

  def build_response(agent_id, query_id, {:error, reason}) when is_binary(agent_id) do
    {:ok, signal} =
      Jido.Signal.new(
        "agents.#{agent_id}.directive",
        %{
          query_id: query_id,
          error: reason
        },
        source: "foreman.task_metadata_query_responder"
      )

    signal
  end

  @doc """
  Look up a task via the supplied provider function.

  ## Arguments

    - `provider` — a 1-arity function `(task_id) -> {:ok, task} | {:error, reason}`.
      In production this is a closure over `ForemanServer.TaskProvider.get/2`; in
      tests it is a stub.
    - `task_id` — the task id to look up.

  ## Returns

  The provider's return value (passed through unchanged).
  """
  @spec lookup((String.t() -> {:ok, term()} | {:error, term()}), String.t()) ::
          {:ok, term()} | {:error, term()}
  def lookup(provider, task_id) when is_function(provider, 1) and is_binary(task_id) do
    provider.(task_id)
  end
end
