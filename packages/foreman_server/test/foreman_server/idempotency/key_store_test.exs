defmodule ForemanServer.Idempotency.KeyStoreTest do
  use ExUnit.Case, async: false

  test "lifecycle started -> completed" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_started("k1", %{workflow: "wf-1"})
    assert {:ok, :started} = ForemanServer.Idempotency.KeyStore.status("k1")
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed("k1", %{result: :ok})
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status("k1")
  end

  test "ambiguous status for timeout" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_started("k2")
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k2", "expired")
    assert {:ok, :ambiguous} = ForemanServer.Idempotency.KeyStore.status("k2")
  end

  test "status of unknown key is :not_found" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert :not_found = ForemanServer.Idempotency.KeyStore.status("unknown")
  end
end
