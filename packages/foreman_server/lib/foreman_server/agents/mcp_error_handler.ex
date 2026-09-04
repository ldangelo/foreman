defmodule ForemanServer.Agents.McpErrorHandler do
  @moduledoc """
  Classifies MCP errors as recoverable or non-recoverable; emits a directive
  that downstream dispatchers can act on (retry, escalate, or log only).
  TRD-2026-4212be7e / MCP-T006 / TRD-053.
  """

  require Logger

  @recoverable [:timeout, :connection_lost, :rate_limited, :transient]

  @non_recoverable [
    :auth_failed,
    :permission_denied,
    :not_found,
    :schema_invalid,
    :unsupported_version
  ]

  @doc """
  Classify an MCP error kind into `{category, action}` where `category` is
  `:recoverable | :non_recoverable | :unknown` and `action` is
  `:retry | :escalate | :log`.
  """
  def classify(error_kind) do
    cond do
      error_kind in @recoverable -> {:recoverable, :retry}
      error_kind in @non_recoverable -> {:non_recoverable, :escalate}
      true -> {:unknown, :log}
    end
  end

  @doc """
  Handle an MCP error: log at the appropriate level, and return
  `{action, directive}` so the caller can drive its dispatcher.
  """
  def handle(error_kind, context \\ %{}) do
    case classify(error_kind) do
      {:recoverable, :retry} ->
        Logger.warning("MCP recoverable: #{error_kind}; emitting retry directive")
        {:retry, directive(error_kind, context)}

      {:non_recoverable, :escalate} ->
        Logger.error("MCP non-recoverable: #{error_kind}; escalating")
        {:escalate, directive(error_kind, context)}

      {:unknown, :log} ->
        Logger.warning("MCP unknown: #{error_kind}; logging only")
        {:log, directive(error_kind, context)}
    end
  end

  defp directive(kind, context) do
    %{
      kind: kind,
      action: elem(classify(kind), 1),
      context: context,
      emitted_at: System.system_time(:millisecond)
    }
  end
end
