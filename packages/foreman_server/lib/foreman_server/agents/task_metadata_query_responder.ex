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
  @doc """
  Handle an incoming query signal end-to-end: extract task_id, look
  up the task via the supplied provider, build a response signal,
  and publish it back to the agent on the directive bus.

  ## Arguments

    - `query_signal` — the %Jido.Signal{} struct published by the agent
      on the `com.foreman.query.task_metadata.<project>` topic. Must
      have `:task_id`, `:agent_id`, and `:query_id` in `data`.
    - `bus` — the bus to publish the response on. Pass a registered
      name, a pid, or `:default` (resolves to `:foreman_jido_signal_bus`).
    - `provider` — a 1-arity function `(task_id) -> {:ok, task} | {:error, reason}`.
      In production this is a closure over `ForemanServer.TaskProvider.get/2`.

  ## Returns

  `{:ok, {:response, recorded_signal}}` on successful publish,
  `{:error, reason}` if the query data is missing required fields
  or the publish fails. The provider's `{:error, reason}` is
  propagated as a response with `data.error` set to `reason`.
  """
  @spec respond(struct(), GenServer.server() | :default, (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, {:response, Jido.Signal.Bus.RecordedSignal.t()}} | {:error, term()}
  def respond(query_signal, bus, provider)
      when is_struct(query_signal, Jido.Signal) and is_function(provider, 1) do
    with {:ok, task_id} <- Map.fetch(query_signal.data, :task_id),
         {:ok, agent_id} <- Map.fetch(query_signal.data, :agent_id),
         {:ok, query_id} <- Map.fetch(query_signal.data, :query_id) do
      result = provider.(task_id)
      response_signal = build_response(agent_id, query_id, result)
      ForemanServer.Agents.SignalDirectivePublisher.publish(bus, agent_id, response_signal.data)
      |> case do
        {:ok, [recorded]} -> {:ok, {:response, recorded}}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :malformed_query}
    end
  end
end
