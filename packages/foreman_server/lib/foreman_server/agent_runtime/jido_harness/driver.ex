defmodule ForemanServer.AgentRuntime.JidoHarness.Driver do
  @moduledoc false

  alias Jido.Harness.Run

  @spec run(atom(), String.t(), keyword()) ::
          {:ok, Jido.Harness.RunResult.t()} | {:ok, map()} | map() | {:error, term()}
  def run(provider, prompt, opts) when is_atom(provider) and is_binary(prompt) do
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    case Run.start(provider, prompt, upstream_opts(opts)) do
      {:ok, harness_run_id} ->
        notify_on_start(opts[:on_start], harness_run_id)
        Run.await(harness_run_id, await_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec await(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.RunResult.t())
  def await(run_id, timeout), do: Run.await(run_id, timeout)

  defp notify_on_start(nil, _harness_run_id), do: :ok
  defp notify_on_start(on_start, harness_run_id) when is_function(on_start, 1), do: on_start.(harness_run_id)

  defp upstream_opts(opts) do
    opts = Keyword.drop(opts, [:on_start, :await_timeout])
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
