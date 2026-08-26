defmodule ForemanServerWeb.MCP.Tools.Doctor do
  @moduledoc """
  `foreman server doctor` MCP tool — surfaces the readiness of every
  jido_harness provider the dispatch pipeline can target.

  The tool delegates the readiness probe to
  `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck` and renders the
  result as a deterministic multi-line report. The same module is
  invoked by the `ForemanServer.MCP.Tools.call_tool("foreman_doctor", _)`
  plumbing and by the `foreman server doctor` CLI mix task.

  ## Output format

      Provider readiness
      ✓ pi available
      ✗ claude not found — install with: npm install -g @anthropic-ai/claude-code

  ## Strict mode

  When `:strict` is passed and at least one required provider is missing,
  `run/1` returns `{:error, :provider_missing, output}` so callers (CLI
  mix task, CI gates) can fail with a non-zero exit code while still
  surfacing the rendered report.
  """

  alias ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck

  @type provider_result :: {:provider, atom(), :installed | :not_installed, String.t()}

  @spec run(keyword()) :: {:ok, String.t()} | {:error, :provider_missing, String.t()}
  def run(opts \\ []) when is_list(opts) do
    results = rows()
    output = format(results)

    if Keyword.get(opts, :strict, false) and Enum.any?(results, &missing?/1) do
      {:error, :provider_missing, output}
    else
      {:ok, output}
    end
  end

  @doc """
  Returns the raw `{:provider, atom, :installed | :not_installed, hint}`
  rows produced by `ReadinessCheck.run/0`. Used by the `foreman_doctor`
  MCP tool to expose structured rows alongside the formatted output.
  """
  @spec rows() :: [provider_result()]
  def rows, do: ReadinessCheck.run()

  @doc """
  Renders the readiness rows as a multi-line report.
  """
  @spec format([provider_result()]) :: String.t()
  def format(results) when is_list(results), do: ReadinessCheck.format(results)

  @spec missing?(provider_result()) :: boolean()
  defp missing?({:provider, _provider, :not_installed, _hint}), do: true
  defp missing?(_result), do: false
end
