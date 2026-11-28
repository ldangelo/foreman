defmodule ForemanServer.AgentRuntime.AvailabilityCache do
  @moduledoc """
  Bounded, TTL-cached evaluation of an availability probe (foreman-duhcq).

  A probe such as `JidoHarnessAdapter.available?/0` spawns a provider CLI
  (`ReadinessCheck.installed?/1` -> `Jido.Harness.status/1`; the vendored
  `System.cmd` has no timeout), and the router reads availability on every dispatch.
  This module:

    * stores `{key, value, probed_at_ms}` in a public ETS table owned by this (idle)
      supervised process, so reads never go through a GenServer;
    * serves a value younger than the TTL without probing;
    * otherwise probes in a monitored child of the caller, the WHOLE probe bounded by a
      timeout;
    * on a timeout or crash returns the last known value, and with none (first read)
      the optimistic `true`, never `false`: a false first read would turn one slow CLI
      into `:no_available_backend` for every dispatch, and
      `JidoHarnessAdapter.execute/2` re-checks the specific provider anyway. A fallback
      answer is not cached, so the next read probes again.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @default_ttl_ms 5_000
  @default_timeout_ms 3_000

  @type opts :: [ttl_ms: non_neg_integer() | :infinity, timeout_ms: pos_integer()]

  @doc """
  Starts the (otherwise idle) process that owns the cache table. The table is global, so a
  second runtime supervisor (tests) finds it already owned and starts nothing.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Returns `probe.()` as a boolean for `key`, running it at most once per TTL.

  Options: `:ttl_ms` (default #{@default_ttl_ms}; `0` probes every read, `:infinity`
  never expires) and `:timeout_ms` (default #{@default_timeout_ms}), bounding the WHOLE
  probe. Without the owning process (table absent) every read probes, still bounded.
  """
  @spec fetch(term(), (-> boolean()), opts()) :: boolean()
  def fetch(key, probe, opts \\ []) when is_function(probe, 0) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if :ets.whereis(@table) == :undefined do
      probe |> probe_bounded(timeout, nil) |> elem(1)
    else
      fetch_cached(key, probe, ttl, timeout)
    end
  end

  defp fetch_cached(key, probe, ttl, timeout) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, at}] when ttl == :infinity or now - at < ttl ->
        value

      previous ->
        last_known =
          case previous do
            [{^key, value, _}] -> value
            [] -> nil
          end

        case probe_bounded(probe, timeout, last_known) do
          {:fresh, value} ->
            :ets.insert(@table, {key, value, System.monotonic_time(:millisecond)})
            value

          {:fallback, value} ->
            value
        end
    end
  end

  # A failed first probe answers `true` (see moduledoc); a failed later probe answers the
  # last known value. Both are {:fallback, _}: never cached.
  defp probe_bounded(probe, timeout, last_known) do
    case {run_probe(probe, timeout), last_known} do
      {{:ok, value}, _} -> {:fresh, value}
      {:error, nil} -> {:fallback, true}
      {:error, known} -> {:fallback, known}
    end
  end

  defp run_probe(probe, timeout) do
    {pid, ref} = spawn_monitor(fn -> exit({:probe_result, probe.() == true}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:probe_result, value}} ->
        {:ok, value}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning("availability probe crashed: #{inspect(reason)}")
        :error
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end

        Logger.warning("availability probe exceeded #{timeout}ms")
        :error
    end
  end
end
