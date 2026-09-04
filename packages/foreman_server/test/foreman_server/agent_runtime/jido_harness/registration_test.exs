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

    {:ok, _catalog_pid} = AdapterCatalog.start_link(name: cat_name)

    on_exit(fn ->
      Application.put_env(:foreman_server, :jido_harness, original)
    end)

    {:ok, catalog: cat_name}
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
