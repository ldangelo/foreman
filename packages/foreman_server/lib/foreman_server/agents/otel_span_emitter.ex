defmodule ForemanServer.Agents.OtelSpanEmitter do
  @moduledoc """
  Emits OTEL spans for Jido.Agent `cmd/2`, LLM calls, and signal dispatch.

  TRD-2026-4212be7e / JOT-T002 (TRD-060), JOT-T003 (TRD-061), JOT-T004 (TRD-062).
  Backed by `jido_otel` (TRD-059) for tracer configuration.

  Each emit function is a leaf call (no callable block) suitable for
  instrumentation call sites that have already measured `duration_us` or
  have the LLM/signal attributes in hand.
  """

  require OpenTelemetry.Tracer

  # GenAI semantic-convention agent name, stamped on every span this emitter
  # produces (each is the root of its own trace, so Lens reads it there). The
  # project's stable name, not the OTel service.name (`foreman_server`).
  @agent_name "foreman"

  @doc """
  Run `fun` inside a root agent span named `span_name`, carrying
  `gen_ai.agent.name` and `gen_ai.operation.name = "invoke_agent"` plus
  `attributes`, and return `fun`'s result unchanged. Unlike the leaf emitters
  this wraps the work, so an agent turn or workflow phase is one trace with the
  agent name on its root span. An `{:error, _}` result marks the span errored;
  an exception is recorded by `with_span` and re-raised.
  """
  @spec with_agent_span(String.t(), %{String.t() => String.t() | number()}, (-> result)) ::
          result
        when result: term()
  def with_agent_span(span_name, attributes, fun)
      when is_binary(span_name) and is_map(attributes) and is_function(fun, 0) do
    base = %{"gen_ai.agent.name" => @agent_name, "gen_ai.operation.name" => "invoke_agent"}

    OpenTelemetry.Tracer.with_span span_name, %{attributes: Map.merge(base, attributes)} do
      result = fun.()

      case result do
        {:error, _, _} -> OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "error"))
        {:error, _} -> OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "error"))
        _ -> :ok
      end

      result
    end
  end

  @doc """
  Emit a `jido.cmd` span capturing the agent id, action name, and duration
  in microseconds. Called from the Jido `cmd/2` instrumentation hook.
  """
  @spec emit_cmd_span(String.t(), String.t(), non_neg_integer()) :: :ok
  def emit_cmd_span(agent_id, action_name, duration_us)
      when is_binary(agent_id) and is_binary(action_name) and is_integer(duration_us) do
    OpenTelemetry.Tracer.with_span "jido.cmd",
                                   %{
                                     attributes: %{
                                       "gen_ai.agent.name" => @agent_name,
                                       "jido.agent_id" => agent_id,
                                       "jido.action" => action_name,
                                       "duration_us" => duration_us
                                     }
                                   } do
      :ok
    end
  end

  @doc """
  Emit a `jido.llm` span capturing the model, token counts, cost, and routing
  reason. Called from the LiteLLM/Langfuse call site (TRD-061).

  `token_count` and `cost_usd` are `nil` when the provider reported none; the
  `llm.tokens` / `llm.cost_usd` attributes are then omitted rather than
  recorded as misleading zeros.
  """
  @spec emit_llm_span(String.t(), non_neg_integer() | nil, number() | nil, String.t()) :: :ok
  def emit_llm_span(model, token_count, cost_usd, routing_reason)
      when is_binary(model) and (is_integer(token_count) or is_nil(token_count)) and
             is_binary(routing_reason) and
             (is_number(cost_usd) or is_nil(cost_usd)) do
    attributes = llm_span_attributes(model, token_count, cost_usd, routing_reason)

    OpenTelemetry.Tracer.with_span "jido.llm", %{attributes: attributes} do
      :ok
    end
  end

  @doc """
  The attribute map of a `jido.llm` span. `llm.tokens` / `llm.cost_usd` are
  present only when known: an absent key means unknown, never zero.
  """
  @spec llm_span_attributes(String.t(), non_neg_integer() | nil, number() | nil, String.t()) ::
          %{String.t() => String.t() | number()}
  def llm_span_attributes(model, token_count, cost_usd, routing_reason) do
    %{
      "gen_ai.agent.name" => @agent_name,
      "llm.model" => model,
      "llm.routing_reason" => routing_reason
    }
    |> put_unless_nil("llm.tokens", token_count)
    |> put_unless_nil("llm.cost_usd", cost_usd)
  end

  defp put_unless_nil(attrs, _key, nil), do: attrs
  defp put_unless_nil(attrs, key, value), do: Map.put(attrs, key, value)

  @doc """
  Emit a `jido.signal` span capturing the signal type, topic, and delivery
  status. Called from signal publish/dispatch instrumentation (TRD-062).
  """
  @spec emit_signal_span(String.t(), String.t(), String.t()) :: :ok
  def emit_signal_span(signal_type, topic, delivery_status)
      when is_binary(signal_type) and is_binary(topic) and is_binary(delivery_status) do
    OpenTelemetry.Tracer.with_span "jido.signal",
                                   %{
                                     attributes: %{
                                       "gen_ai.agent.name" => @agent_name,
                                       "signal.type" => signal_type,
                                       "signal.topic" => topic,
                                       "signal.delivery_status" => delivery_status
                                     }
                                   } do
      :ok
    end
  end
end
