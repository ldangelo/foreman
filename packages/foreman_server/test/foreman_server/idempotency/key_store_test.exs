defmodule ForemanServer.Idempotency.KeyStoreTest do
  @moduledoc """
  Tests for `ForemanServer.Idempotency.KeyStore` — durable idempotency
  key records with status {started, completed, ambiguous}.

  TRD-2026-4212be7e / RTE-T001 / TRD-075.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore

  # Restore original app env in on_exit so subsequent test files are unaffected.
  setup do
    original = Application.get_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, original)
    end)

    :ok
  end

  # --- ETS fallback mode (repo not configured) ---

  describe "fallback mode (no repo)" do
    setup do
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])

      # KeyStore is a named GenServer that may already be running from a
      # prior async:false test file with a different repo config.
      # Gracefully handle {:already_started,pid} and always ensure a clean ETS table.
      case KeyStore.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Wipe stale entries left by prior test files before each test.
      if :ets.info(:foreman_idempotency_keys) != :undefined do
        :ets.delete_all_objects(:foreman_idempotency_keys)
      end

      on_exit(fn ->
        if :ets.info(:foreman_idempotency_keys) != :undefined do
          :ets.delete_all_objects(:foreman_idempotency_keys)
        end
      end)
    end

    test "lifecycle started -> completed" do
      :ok = KeyStore.mark_started("k1", %{workflow: "wf-1"})
      assert {:ok, :started} = KeyStore.status("k1")

      :ok = KeyStore.mark_completed("k1", %{result: :ok})
      assert {:ok, :completed} = KeyStore.status("k1")
    end

    test "lifecycle started -> ambiguous" do
      :ok = KeyStore.mark_started("k2")
      :ok = KeyStore.mark_ambiguous("k2", "expired")
      assert {:ok, :ambiguous} = KeyStore.status("k2")
    end

    test "status of unknown key is :not_found" do
      assert :not_found = KeyStore.status("unknown")
    end

    test "mark_started is idempotent (same status, updated metadata)" do
      :ok = KeyStore.mark_started("k3", %{step: 1})
      :ok = KeyStore.mark_started("k3", %{step: 1})
      assert {:ok, :started} = KeyStore.status("k3")
    end

    test "get/1 returns full record with metadata" do
      :ok = KeyStore.mark_started("k4", %{workflow: "impl", step: 2})
      assert {:ok, %{key: "k4", status: :started, metadata: %{workflow: "impl", step: 2}}} =
               KeyStore.get("k4")
    end

    test "get/1 returns :not_found for unknown key" do
      assert :not_found = KeyStore.get("does-not-exist")
    end

    test "list_by_status/1 returns keys with matching status" do
      :ok = KeyStore.mark_started("k-a")
      :ok = KeyStore.mark_started("k-b")
      :ok = KeyStore.mark_completed("k-c")

      started = KeyStore.list_by_status(:started)
      assert Enum.sort(started) == Enum.sort(["k-a", "k-b"])

      completed = KeyStore.list_by_status(:completed)
      assert completed == ["k-c"]
    end

    test "list_by_status/1 returns empty list when no matches" do
      assert KeyStore.list_by_status(:completed) == []
    end
  end

  # --- Key format validation ---

  describe "key format (REQ-026)" do
    setup do
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])

      case KeyStore.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      if :ets.info(:foreman_idempotency_keys) != :undefined do
        :ets.delete_all_objects(:foreman_idempotency_keys)
      end

      on_exit(fn ->
        if :ets.info(:foreman_idempotency_keys) != :undefined do
          :ets.delete_all_objects(:foreman_idempotency_keys)
        end
      end)
    end

    test "create workflow key format: create-prd-{taskId}-{step}" do
      key = "create-prd-task-123-1"
      :ok = KeyStore.mark_started(key)
      assert {:ok, :started} = KeyStore.status(key)
      :ok = KeyStore.mark_completed(key)
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "implement workflow key format: implement-{taskId}-1" do
      key = "implement-task-456-1"
      :ok = KeyStore.mark_started(key)
      assert {:ok, :started} = KeyStore.status(key)
    end

    test "fix workflow key format: fix-{taskId}-1" do
      key = "fix-task-789-1"
      :ok = KeyStore.mark_started(key)
      assert {:ok, :started} = KeyStore.status(key)
    end
  end
end
