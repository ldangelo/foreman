defmodule ForemanServer.AgentRuntime.JidoHarness.RegistrationTest do
  @moduledoc """
  TRD-004 — verifies the conditional registration gate in
  `ForemanServer.Application.start/2` that registers
  `JidoHarnessAdapter` with the AgentRuntime catalog when
  `:jido_harness, :enabled` is true.

  Uses `async: false` because the registration flow mutates the global
  `:foreman_server, :jido_harness` Application env key and the global
  `AdapterCatalog` GenServer; concurrent tests would race on those
  reads and pollute each other's baseline.

  Each test starts a fresh `AdapterCatalog` under a unique name in
  `setup` (using `Process.flag(:trap_exit, true)` so its lifecycle is
  decoupled from the test process) instead of relying on the
  application-started global catalog. That keeps the catalog state
  isolated per case while still exercising the same registration gate
  semantics and restoring the `:jido_harness` Application env in
  `on_exit`. The catalog's Registry entries are released when the
  catalog process exits naturally.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter

  setup do
    original = Application.get_env(:foreman_server, :jido_harness)
    Application.put_env(:foreman_server, :jido_harness, [])

    # Trap exits so the catalog started below is not propagated-killed
    # when the test process terminates.
    Process.flag(:trap_exit, true)

    cat_name =
      :"AdapterCatalog.JidoHarness.RegistrationTest.#{System.unique_integer([:positive])}"

    # `AdapterCatalog.lookup/2` reads the GLOBAL `AdapterRegistry`, not the catalog
    # named above, and a dead catalog's entries are removed asynchronously. Without
    # this wait a previous case's `:jido_harness` entry can still be visible here
    # under load, which made the "enabled: false" case find an adapter it never
    # registered.
    await_registry_clear()

    {:ok, catalog_pid} = AdapterCatalog.start_link(name: cat_name)

    on_exit(fn ->
      Application.put_env(:foreman_server, :jido_harness, original)
      stop_catalog(catalog_pid)
    end)

    {:ok, catalog: cat_name}
  end

  @registry ForemanServer.AgentRuntime.AdapterRegistry

  defp registry_clear? do
    Registry.lookup(@registry, :jido_harness) == []
  rescue
    # The registry is owned by (linked to) the catalog that created it and is gone
    # with it: nothing is registered.
    ArgumentError -> true
  end

  defp await_registry_clear(deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      registry_clear?() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("a :jido_harness entry stayed in the global AdapterRegistry for 5s")

      true ->
        Process.sleep(5)
        await_registry_clear(deadline)
    end
  end

  defp stop_catalog(pid) do
    ref = Process.monitor(pid)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("the test's AdapterCatalog did not stop")
    end

    await_registry_clear()
  end

  # Mirrors the conditional registration block in
  # ForemanServer.Application.start/2 (TRD-004). Kept verbatim here so
  # the test exercises the exact same gate semantics the application
  # boots with.
  defp apply_registration_gate(catalog) do
    if Application.get_env(:foreman_server, :jido_harness, [])[:enabled] == true do
      # Production application uses AgentRuntime.register/1 which
      # hardcodes the global AdapterCatalog. For an isolated test we
      # route through AgentRuntime.register_adapter/2 against the
      # fresh catalog (same validate + register protocol).
      case AgentRuntime.register_adapter(JidoHarnessAdapter, catalog: catalog) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  describe "registration gate (TRD-004)" do
    test "with :jido_harness enabled: true, the adapter is registered in AdapterCatalog",
         %{catalog: catalog} do
      Application.put_env(:foreman_server, :jido_harness, enabled: true)

      apply_registration_gate(catalog)

      assert AdapterCatalog.lookup(:jido_harness, catalog) == {:ok, JidoHarnessAdapter}
      assert JidoHarnessAdapter in AdapterCatalog.snapshot(catalog)
    end

    test "with :jido_harness enabled: false, the adapter is NOT registered",
         %{catalog: catalog} do
      Application.put_env(:foreman_server, :jido_harness, enabled: false)

      apply_registration_gate(catalog)

      assert AdapterCatalog.lookup(:jido_harness, catalog) == {:error, :not_found}
      refute JidoHarnessAdapter in AdapterCatalog.snapshot(catalog)
    end

    test "the registered adapter's name/0 returns :jido_harness" do
      assert JidoHarnessAdapter.name() == :jido_harness
    end
  end
end
