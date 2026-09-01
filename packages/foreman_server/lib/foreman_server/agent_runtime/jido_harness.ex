defmodule ForemanServer.AgentRuntime.JidoHarness do
  @moduledoc """
  Namespace module exposing the canonical provider list and
  provider-keyed helpers for the jido_harness adapter integration.

  TRD-2026-8a1f3c2e / TRD-008 — `:claude` provider registration.

  Both `:pi` and `:claude` are routed through the same
  `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter` facade; this
  module is the single source of truth for the supported provider list
  and the `request_provider/1` helper that resolves the requested
  provider from a request context.

  Pure, stateless, no I/O, no supervision.
  """

  @supported_providers [:pi, :claude, :litellm]

  @doc """
  Returns the canonical list of supported providers.
  """
  @spec providers() :: [atom()]
  def providers, do: @supported_providers

  @doc """
  Returns `true` if `provider` is one of `:pi`, `:claude`, or `:litellm`.
  """
  @spec provider(term()) :: boolean()
  def provider(p) when is_atom(p), do: p in @supported_providers
  def provider(_), do: false

  @doc """
  Resolves the requested provider from a `BackendAdapter.request/0`
  map. Reads `request.context.provider` if present (any atom or string),
  otherwise defaults to `:pi`. Unknown atoms are returned unchanged so
  the adapter's `provider not in @supported_providers` branch can fire
  `{:error, :unsupported_provider}`.
  """
  @spec request_provider(map()) :: atom()
  def request_provider(%{context: context}) when is_map(context) do
    case Map.get(context, :provider) || Map.get(context, "provider") do
      nil ->
        :pi

      "pi" ->
        :pi

      "claude" ->
        :claude

      "litellm" ->
        :litellm

      p when is_binary(p) ->
        case String.downcase(p) do
          "litellm" -> :litellm
          _ -> p
        end

      p when is_atom(p) ->
        p
    end
  end

  def request_provider(_request), do: :pi
end
