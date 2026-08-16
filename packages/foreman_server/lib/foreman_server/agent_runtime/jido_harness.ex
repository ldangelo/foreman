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

  @supported_providers [:pi, :claude]

  @doc """
  Returns the canonical list of supported providers.

  Mirrors `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck`'s
  supported list and the `JidoHarnessAdapter` registry. The vendored
  `Jido.Harness.run/3` accepts both `:pi` and `:claude` through the
  same call API; this module is the Foreman-side source of truth.
  """
  @spec supported?() :: [atom()]
  def supported?, do: @supported_providers

  @doc """
  Returns `true` if `provider` is one of `:pi` or `:claude`.

  Any non-atom argument (string, integer, nil, etc.) returns `false`
  so callers can pass raw context values without first pattern-matching.
  `nil` is technically an atom in Elixir but is not a supported
  provider, so it returns `false` anyway.
  """
  @spec provider?(term()) :: boolean()
  def provider?(p) when is_atom(p), do: p in @supported_providers
  def provider?(_), do: false

  @doc """
  Resolves `request.context.provider` to a supported provider atom.

  Defaults to `:pi` when the request lacks a `:provider` (or `"provider"`)
  key in its context. The string-keyed form is accepted for parity with
  JSON-decoded contexts; both `"pi"` and `"claude"` are normalized to
  their atom equivalents.

  Unknown atoms/strings are returned unchanged so the adapter can
  surface `:unsupported_provider` for them — the existing fallback
  behavior preserved from the prior private `requested_provider/1`
  helper in `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`.

  Mirrors the prior private `requested_provider/1` helper in
  `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter` but operates
  at the request level (one argument instead of unwrapping `context`
  at the call site).
  """
  @spec request_provider(map()) :: atom()
  def request_provider(%{context: context}) when is_map(context) do
    case Map.get(context, :provider) || Map.get(context, "provider") do
      nil -> :pi
      "pi" -> :pi
      "claude" -> :claude
      provider -> provider
    end
  end

  def request_provider(_request), do: :pi
end
