defmodule ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter do
  @moduledoc """
  BackendAdapter wrapper around the vendored `Jido.Harness` runtime.

  Foreman keeps the public `:timeout_ms` execution option, while the internal
  driver translates it to the vendored harness request field that the current
  upstream actually accepts (`:runtime_timeout_ms`).
  """

  @behaviour ForemanServer.AgentRuntime.BackendAdapter

  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.AgentRuntime.JidoHarness.{Driver, ErrorCodes, ReadinessCheck, RunResult}
  alias ForemanServer.Telemetry

  @default_timeout_ms 60_000
  @default_await_timeout :infinity
  @supported_providers [:pi, :claude, :litellm]
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

  @doc """
  Adapter contract — `WorkerProtocol.start_worker/3` calls this to spawn
  a supervised worker that runs the Jido.Harness agent. Forwards to
  `ForemanServer.Overwatch.Adapters.JidoHarnessWorker.start_link/1`.

  Required opts passed through from `Overwatch.start_phase/2`:
  `:worker_id`, `:run_id`, `:provider`, `:prompt`, `:driver_opts`,
  `:result_recipient`. See `JidoHarnessWorker` for the full contract.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ForemanServer.Overwatch.Adapters.JidoHarnessWorker.start_link(opts)
  end

  @impl true
  def available? do
    ReadinessCheck.installed?(:pi) or ReadinessCheck.installed?(:claude) or
      ReadinessCheck.installed?(:litellm)
  end

  @impl true
  @spec execute(BackendAdapter.request(), BackendAdapter.exec_opts()) ::
          BackendAdapter.execute_result()
  def execute(request = %{prompt: prompt, context: context}, opts)
      when is_binary(prompt) and is_map(context) do
    provider = JidoHarness.request_provider(request)
    started_at_ms = System.monotonic_time(:millisecond)

    {result, run_id} =
      cond do
        provider not in @supported_providers ->
          {{:error, :unsupported_provider}, ""}

        not ReadinessCheck.installed?(provider) ->
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

              case Driver.await(
                     run_id,
                     Keyword.get(
                       driver_opts(context, opts),
                       :await_timeout,
                       @default_await_timeout
                     )
                   ) do
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

  defp driver_opts(context, opts) do
    opts
    |> translate_timeout_ms()
    |> Keyword.put_new(:timeout, @default_timeout_ms)
    |> Keyword.put_new(:await_timeout, @default_await_timeout)
    |> maybe_put_cwd(context)
    |> maybe_put_model(context)
    |> maybe_put_env(Keyword.get(opts, :env, %{}))
  end

  defp maybe_put_cwd(opts, context) do
    case Map.get(context, :working_directory) || Map.get(context, "working_directory") do
      dir when is_binary(dir) and dir != "" -> Keyword.put(opts, :cwd, dir)
      _ -> opts
    end
  end

  defp maybe_put_env(opts, env) when is_map(env) and map_size(env) > 0,
    do: Keyword.put(opts, :env, env)

  defp maybe_put_env(opts, _env), do: opts

  defp error_run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp error_run_id(_reason), do: ""

  defp translate_timeout_ms(opts) do
    case Keyword.pop(opts, :timeout_ms) do
      {nil, rest} -> rest
      {timeout_ms, rest} -> Keyword.put_new(rest, :timeout, timeout_ms)
    end
  end

  @doc """
  Normalizes a raw `Driver.run/3` or `Driver.await/2` failure reason into a
  stable `{:error, code}` failure tuple.

  In this position the harness's declared reason shape is a bare atom
  (`:timeout`, `:not_found`, a supervisor's `:shutdown`, ...) or a
  `%Jido.Harness.Error{}`. A bare atom therefore carries real information
  and MUST survive: it is routed through the single
  `ForemanServer.AgentRuntime.JidoHarness.ErrorCodes` table under the key
  that table reads, so a recognized atom becomes its declared code and any
  other atom is preserved as `{:other, atom}`. That replaces the
  hand-maintained pass-through list that used to live here — a second copy
  of `ErrorCodes`'s known-code map (AGENTS.md §5.7) whose omission of
  `:shutdown` and `:not_found` reported both as `:unknown_error`.

  A `%Jido.Harness.Error{}` reason is delegated to the same table, which
  reads its `:category`.

  `:unknown_error` is now reserved for a reason that is neither an atom nor
  a `%{code: _}` map, i.e. one that genuinely carries no interpretable
  failure category (AGENTS.md §5.3).
  """
  @spec normalize_raw_error(term()) :: ErrorCodes.code()
  def normalize_raw_error(reason) when is_atom(reason) and not is_nil(reason),
    do: ErrorCodes.map(%{code: reason})

  def normalize_raw_error(reason) do
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

  defp maybe_put_model(opts, context) do
    model = Map.get(context, "model") || Map.get(context, :model)

    if is_binary(model) and model != "",
      do: Keyword.put_new(opts, :model, model),
      else: opts
  end
end
