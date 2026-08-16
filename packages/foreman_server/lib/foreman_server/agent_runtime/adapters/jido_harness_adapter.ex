defmodule ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter do
  @moduledoc """
  BackendAdapter wrapper around the vendored `Jido.Harness` runtime.

  Foreman keeps the public `:timeout_ms` execution option, while the internal
  driver translates it to the vendored harness request field that the current
  upstream actually accepts (`:runtime_timeout_ms`).
  """

  @behaviour ForemanServer.AgentRuntime.BackendAdapter

  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.AgentRuntime.JidoHarness.{Driver, ErrorCodes, ReadinessCheck, RunResult}
  alias ForemanServer.Telemetry

  @default_timeout_ms 60_000
  @default_await_timeout :infinity
  @supported_providers [:pi, :claude]
  @telemetry_event [:foreman, :dispatch, :run, :stop]

  @impl true
  def name, do: :jido_harness

  @impl true
  def capabilities do
    %{
      type: :cli,
      strengths: [:code_generation, :code_review, :refactor],
      weaknesses: [:long_context],
      supported_contexts: [:implement, :refactor, :review, :explain]
    }
  end

  @impl true
  def available? do
    enabled?() and (ReadinessCheck.installed?(:pi) or ReadinessCheck.installed?(:claude))
  end

  # Per-deployment rollout switch (PRD-2026-016 §3.4): when the
  # :jido_harness, :enabled config is false, the adapter must reject
  # every run regardless of provider availability. This is the in-code
  # counterpart of the FOREMAN_USE_JIDO_HARNESS env var.
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:foreman_server, :jido_harness, [])
    |> Keyword.get(:enabled, false) == true
  end

  @impl true
  @spec execute(BackendAdapter.request(), BackendAdapter.exec_opts()) :: BackendAdapter.execute_result()
  def execute(%{prompt: prompt, context: context}, opts) when is_binary(prompt) and is_map(context) do
    provider = requested_provider(context)
    started_at_ms = System.monotonic_time(:millisecond)

    {result, run_id} =
      cond do
        provider not in @supported_providers ->
          {{:error, :unsupported_provider}, ""}

        not enabled?() ->
          # Honor the :jido_harness, :enabled config flag. This is the
          # per-deployment rollout switch (see PRD-2026-016 §3.4):
          # Phase 1 defaults to false; operators opt in with
          # FOREMAN_USE_JIDO_HARNESS=true. With the flag false, even an
          # installed provider must not run.
          {{:error, :backend_unavailable}, ""}

        not ReadinessCheck.installed?(provider) ->
          # Per-provider check (not the OR-check in available?/0):
          # :pi not installed must fail when :pi is requested, even if
          # :claude is installed (and vice versa). available?/0 reports
          # whether the adapter can run AT ALL; execute/2 enforces
          # readiness for the SPECIFIC provider.
          {{:error, :backend_unavailable}, ""}

        true ->
          case Driver.run(provider, prompt, driver_opts(context, opts)) do
            {:ok, %Jido.Harness.RunResult{} = run_result} ->
              {RunResult.normalize(run_result), run_result.run_id}

            {:ok, detached} when is_map(detached) ->
              run_id = error_run_id(detached)

              case Driver.await(run_id, Keyword.get(driver_opts(context, opts), :await_timeout, @default_await_timeout)) do
                {:ok, %Jido.Harness.RunResult{} = run_result} ->
                  {RunResult.normalize(run_result), run_result.run_id}

                {:error, reason} ->
                  {normalize_raw_error(reason), run_id}
              end

            {:error, reason} ->
              {normalize_raw_error(reason), error_run_id(reason)}
          end
      end

    emit_stop(started_at_ms, provider, run_id, result)
    result
  end

  def execute(_request, _opts), do: {:error, :invalid_request}

  defp requested_provider(context) when is_map(context) do
    case Map.get(context, :provider) || Map.get(context, "provider") do
      nil -> :pi
      "pi" -> :pi
      "claude" -> :claude
      provider -> provider
    end
  end

  defp driver_opts(context, opts) do
    opts
    |> translate_timeout_ms()
    |> Keyword.put_new(:timeout, @default_timeout_ms)
    |> Keyword.put_new(:await_timeout, @default_await_timeout)
    |> maybe_put_cwd(context)
    |> maybe_put_env(Keyword.get(opts, :env, %{}))
  end

  defp maybe_put_cwd(opts, context) do
    case Map.get(context, :working_directory) || Map.get(context, "working_directory") do
      dir when is_binary(dir) and dir != "" -> Keyword.put(opts, :cwd, dir)
      _ -> opts
    end
  end

  defp maybe_put_env(opts, env) when is_map(env) and map_size(env) > 0, do: Keyword.put(opts, :env, env)
  defp maybe_put_env(opts, _env), do: opts

  defp error_run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp error_run_id(_reason), do: ""


  defp translate_timeout_ms(opts) do
    case Keyword.pop(opts, :timeout_ms) do
      {nil, rest} -> rest
      {timeout_ms, rest} -> Keyword.put_new(rest, :timeout, timeout_ms)
    end
  end

  defp normalize_raw_error(reason) when reason in [:tool_error, :process_terminated, :unsupported_provider, :timeout, :cancelled],
    do: {:error, reason}

  defp normalize_raw_error(reason) do
    case ErrorCodes.map(reason) do
      {:error, _} = error -> error
      nil -> {:error, :unknown_error}
    end
  end
  defp emit_stop(started_at_ms, provider, run_id, result) do
    duration_ms = max(System.monotonic_time(:millisecond) - started_at_ms, 0)

    Telemetry.execute(
      @telemetry_event,
      %{duration_ms: duration_ms},
      %{
        provider: provider,
        status: result_status(result),
        run_id: run_id,
        adapter: :jido_harness
      }
    )
  end

  defp result_status({:ok, _, _}), do: :ok
  defp result_status({:error, _}), do: :error
end