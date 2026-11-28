defmodule ForemanServer.AgentRuntime.AdapterCatalogBootTest do
  @moduledoc """
  foreman-duhcq: the catalog must never run an adapter's `available?/0` probe
  inside its own process. A slow probe (provider CLI spawn) used to block
  catalog init/registration past the 5s GenServer.call timeout and abort boot.
  The probe here parks on a gate message the test releases; no sleeps.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.AdapterCatalog

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

    assert {:ok, {:ok, pid}} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
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
end
