defmodule ForemanServer.AgentRuntime.AdapterCatalogBootTest do
  @moduledoc """
  foreman-duhcq: the catalog must never run an adapter's `available?/0` probe
  inside its own process. A slow probe (provider CLI spawn) used to block
  catalog init/registration past the 5s GenServer.call timeout and abort boot.
  The probe here parks on a gate message the test releases; no sleeps.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.AvailabilityCache

  defmodule GatedAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter
    @impl true
    def name, do: :gated_probe
    @impl true
    def capabilities do
      %{type: :language_model, strengths: [:coding], weaknesses: [], supported_contexts: [:chat]}
    end

    @impl true
    def available? do
      tester = :persistent_term.get({__MODULE__, :tester})
      send(tester, {:probe_started, self()})

      receive do
        :release_probe -> true
      end
    end

    @impl true
    def execute(_req, _opts), do: {:ok, "x", %{}}
  end

  setup do
    :persistent_term.put({GatedAdapter, :tester}, self())
    on_exit(fn -> :persistent_term.erase({GatedAdapter, :tester}) end)
  end

  test "startup registration and register/2 complete while the availability probe hangs" do
    name = :"catalog_boot_#{System.unique_integer([:positive])}"

    # Old code probes inside init: start_link would never return (gate unreleased).
    task =
      Task.async(fn -> AdapterCatalog.start_link(name: name, adapters: [GatedAdapter]) end)

    pid =
      case Task.yield(task, 2_000) do
        {:ok, {:ok, pid}} ->
          pid

        nil ->
          # Killing the task also kills the catalog it linked, and with it any parked probe.
          Task.shutdown(task, :brutal_kill)
          flunk("catalog start blocked on the availability probe")
      end

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert AdapterCatalog.snapshot(name) == [GatedAdapter]
    assert {:ok, GatedAdapter} = AdapterCatalog.lookup(:gated_probe, name)
    assert {:ok, _} = GenServer.call(name, {:register, GatedAdapter}, 1_000)
    refute_received {:probe_started, _}

    # Availability is resolved lazily in the caller, and reflects the live probe.
    caller = Task.async(fn -> AdapterCatalog.available?(GatedAdapter, name) end)
    assert_receive {:probe_started, probe_pid}, 2_000
    refute probe_pid == pid
    send(probe_pid, :release_probe)
    assert Task.await(caller)
  end

  test "routing still resolves to the adapter after registration (availability is never defaulted to false)" do
    name = :"catalog_route_#{System.unique_integer([:positive])}"
    pid = start_supervised!({AdapterCatalog, name: name, adapters: [GatedAdapter]})
    assert is_pid(pid)

    manual =
      Task.async(fn -> ForemanServer.AgentRuntime.Router.manual(:gated_probe, catalog: name) end)

    release_next_probe()
    assert {:ok, GatedAdapter} = Task.await(manual)

    auto =
      Task.async(fn ->
        ForemanServer.AgentRuntime.Router.automatic_candidates(%{},
          catalog: name,
          task_type: :chat
        )
      end)

    release_next_probe()
    assert {:ok, [{GatedAdapter, true}]} = Task.await(auto)
  end

  defp release_next_probe do
    assert_receive {:probe_started, probe_pid}, 2_000
    send(probe_pid, :release_probe)
  end

  defp scripted_probe(replies) do
    script = start_supervised!(Supervisor.child_spec({Agent, fn -> replies end}, id: make_ref()))
    tester = self()

    fn ->
      send(tester, :probed)

      case Agent.get_and_update(script, fn
             [] -> {:crash, []}
             [h | t] -> {h, t}
           end) do
        :hang -> Process.sleep(:infinity)
        :crash -> raise "scripted probe crash"
        value -> value
      end
    end
  end

  defp key, do: {:probe, System.unique_integer([:positive])}

  test "a read within the TTL does not probe again (TTL :infinity)" do
    probe = scripted_probe([true, false])
    k = key()

    assert AvailabilityCache.fetch(k, probe, ttl_ms: :infinity)
    assert_received :probed
    assert AvailabilityCache.fetch(k, probe, ttl_ms: :infinity)
    refute_received :probed
  end

  test "TTL 0 probes on every read and tracks the live value" do
    probe = scripted_probe([true, false])
    k = key()

    assert AvailabilityCache.fetch(k, probe, ttl_ms: 0)
    refute AvailabilityCache.fetch(k, probe, ttl_ms: 0)
    assert_received :probed
    assert_received :probed
  end

  test "a probe slower than the timeout returns the last known value, not false" do
    probe = scripted_probe([false, :hang])
    k = key()
    opts = [ttl_ms: 0, timeout_ms: 50]

    refute AvailabilityCache.fetch(k, probe, opts)
    # hung probe: last known (false) is returned, proving it is not a blanket default
    refute AvailabilityCache.fetch(k, probe, opts)

    probe = scripted_probe([true, :hang])
    k = key()
    assert AvailabilityCache.fetch(k, probe, opts)
    assert AvailabilityCache.fetch(k, probe, opts)
  end

  test "a crashing probe falls back to the last known value" do
    probe = scripted_probe([true])
    k = key()
    opts = [ttl_ms: 0]

    assert AvailabilityCache.fetch(k, probe, opts)
    # script exhausted: the probe crashes
    assert AvailabilityCache.fetch(k, probe, opts)
  end

  test "a first read with a hung probe answers true (optimistic) and is not cached" do
    probe = scripted_probe([:hang, false])
    k = key()
    opts = [ttl_ms: :infinity, timeout_ms: 50]

    assert AvailabilityCache.fetch(k, probe, opts)
    # the optimistic answer was not cached, so the next read probes again and sees the truth
    refute AvailabilityCache.fetch(k, probe, opts)
  end

  test "with adapters: [JidoHarnessAdapter] the supervisor's init registration is the only path and leaves the catalog populated" do
    u = System.unique_integer([:positive])
    catalog = :"boot_catalog_#{u}"

    start_supervised!(
      {ForemanServer.AgentRuntime.Supervisor,
       name: :"boot_sup_#{u}",
       adapter_catalog_name: catalog,
       invocation_supervisor_name: :"boot_inv_#{u}",
       jido_supervisor_name: :"boot_jido_#{u}",
       adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter]}
    )

    refute AdapterCatalog.empty?(catalog)

    assert {:ok, ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter} =
             AdapterCatalog.lookup(:jido_harness, catalog)
  end
end
