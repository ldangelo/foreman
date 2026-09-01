defmodule ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck do
  @moduledoc """
  Probe-based readiness check for jido_harness providers.

  TRD-2026-8a1f3c2e / TRD-005 (Providers + Doctor + Parity).

  Calls `Jido.Harness.status/1` directly. The upstream returns
  `{:ok, %Jido.Harness.ProviderStatus{installed: bool, ...}}` when the
  provider is registered; any other return indicates unavailability. The
  check is intentionally provider-agnostic: callers can probe `:pi`,
  `:claude`, or any future provider atom; unknown atoms return `false`.

  Each `installed?/1` call emits `[:foreman, :dispatch, :provider, :check]`
  telemetry with `%{provider, installed, install_hint}` metadata so the
  supervisor and the doctor MCP tool can observe provider availability
  without re-querying.
  Run `install_hint(:pi)` returns the
  `npm install -g @earendil-works/pi-coding-agent` command. `Run/0`
  returns a row per supported provider shaped as
  `{:provider, :pi | :claude, :installed | :not_installed, hint}`.
  """

  alias ForemanServer.Telemetry

  @supported_providers [:pi, :claude, :litellm]

  @spec installed?(atom()) :: boolean()
  def installed?(provider) when provider in @supported_providers do
    installed =
      case Jido.Harness.status(provider) do
        {:ok, %Jido.Harness.ProviderStatus{installed: true}} -> true
        _ -> false
      end

    Telemetry.dispatch_provider_check(provider, installed, install_hint(provider))
    installed
  end

  def installed?(_provider), do: false

  @spec install_hint(atom()) :: String.t()
  def install_hint(:pi), do: "npm install -g @earendil-works/pi-coding-agent"
  def install_hint(:claude), do: "npm install -g @anthropic-ai/claude-code"
  def install_hint(:litellm), do: "add a ``litellm`` provider to ~/.pi/agent/models.json with a baseUrl pointing to your LiteLLM proxy"
  def install_hint(provider) when is_atom(provider), do: "unknown provider #{inspect(provider)}"
  def install_hint(_), do: "unknown provider"

  @spec run() :: [{:provider, atom(), :installed | :not_installed, String.t()}]
  def run do
    Enum.map(@supported_providers, fn provider ->
      status = if installed?(provider), do: :installed, else: :not_installed
      {:provider, provider, status, install_hint(provider)}
    end)
  end

  @spec format([{:provider, atom(), :installed | :not_installed, String.t()}]) :: String.t()
  def format(results) when is_list(results) do
    rows = Enum.map_join(results, "\n", &format_line/1)
    "Provider readiness\n" <> rows
  end

  defp format_line({:provider, provider, :installed, _hint}), do: "✓ #{provider} available"
  defp format_line({:provider, provider, :not_installed, hint}),
    do: "✗ #{provider} not found — install with: #{hint}"
end
