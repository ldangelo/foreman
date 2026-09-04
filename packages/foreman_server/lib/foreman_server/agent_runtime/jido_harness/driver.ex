defmodule ForemanServer.AgentRuntime.JidoHarness.Driver do
  @moduledoc false

  alias Jido.Harness.Run

  @spec run(atom(), String.t(), keyword()) ::
          {:ok, Jido.Harness.RunResult.t()} | {:ok, map()} | map() | {:error, term()}
  def run(provider, prompt, opts) when is_atom(provider) and is_binary(prompt) do
    provider
    |> Jido.Harness.run(prompt, upstream_opts(opts))
  end

  @spec await(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.RunResult.t())
  def await(run_id, timeout), do: Run.await(run_id, timeout)

  defp upstream_opts(opts) do
    timeouts = Keyword.get_values(opts, :timeout)
    rest = Keyword.drop(opts, [:timeout])

    case List.last(timeouts) do
      nil ->
        rest

      timeout ->
        if Keyword.has_key?(rest, :runtime_timeout_ms) do
          rest
        else
          Keyword.put(rest, :runtime_timeout_ms, timeout)
        end
    end
  end
end
