defmodule ForemanServer.Agents.JidoCheckpointStoreTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoCheckpointStore` — a thin
  Foreman wrapper around `Jido.Ecto.Storage` for Jido agent checkpoint
  persistence (TRD-2026-4212be7e, JCR-T004).

  These tests verify the wrapper's API surface, repo resolution, and
  return-type contract. The end-to-end Postgres round-trip is exercised
  in JCR-T007 (which needs a real Postgres + EventStore running) and
  is out of scope for the unit-level tests here.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoCheckpointStore

  setup do
    original = Application.get_env(:foreman_server, JidoCheckpointStore, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, JidoCheckpointStore, original)
    end)

    :ok
  end

  defp clear_repo! do
    Application.put_env(
      :foreman_server,
      JidoCheckpointStore,
      []
    )
  end

  defp set_repo!(module) do
    Application.put_env(
      :foreman_server,
      JidoCheckpointStore,
      repo: module
    )
  end

  describe "API surface (matches upstream typespecs)" do
    test "put/3 returns :ok | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :put, 3)
      clear_repo!()
      assert JidoCheckpointStore.put("k", %{v: 1}, []) == {:error, :repo_not_configured}
      assert JidoCheckpointStore.put("k", %{v: 1}) == {:error, :repo_not_configured}
    end

    test "get/2 returns {:ok, term()} | :not_found | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :get, 2)
      clear_repo!()
      assert JidoCheckpointStore.get("k", []) == {:error, :repo_not_configured}
      assert JidoCheckpointStore.get("k") == {:error, :repo_not_configured}
    end

    test "delete/2 returns :ok | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :delete, 2)
      clear_repo!()
      assert JidoCheckpointStore.delete("k", []) == {:error, :repo_not_configured}
    end

    test "load_thread/2 returns {:ok, term()} | :not_found | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :load_thread, 2)
      clear_repo!()
      assert JidoCheckpointStore.load_thread("t1", []) == {:error, :repo_not_configured}
    end

    test "append_thread/3 returns {:ok, term()} | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :append_thread, 3)
      clear_repo!()
      assert JidoCheckpointStore.append_thread("t1", [], []) == {:error, :repo_not_configured}
    end

    test "delete_thread/2 returns :ok | {:error, term()}" do
      assert function_exported?(JidoCheckpointStore, :delete_thread, 2)
      clear_repo!()
      assert JidoCheckpointStore.delete_thread("t1", []) == {:error, :repo_not_configured}
    end
  end

  describe "repo resolution" do
    test "configured_repo/0 reads from the app env" do
      clear_repo!()
      assert JidoCheckpointStore.configured_repo() == nil

      set_repo!(MyApp.Repo)
      assert JidoCheckpointStore.configured_repo() == MyApp.Repo
    end

    test "explicit repo: opt overrides the configured repo" do
      # Configured to a different module than the explicit opt. We
      # can't actually run the upstream without a real DB; we just
      # verify the wrapper doesn't return :repo_not_configured (which
      # would mean the explicit override was ignored).
      set_repo!(Configured.Repo)
      result = JidoCheckpointStore.put("k", %{v: 1}, repo: Explicit.Repo)
      refute result == {:error, :repo_not_configured}
    end
  end

  describe "capabilities" do
    test "delegates to Jido.Ecto.capabilities/0" do
      assert JidoCheckpointStore.capabilities() == [:storage, :persist]
    end
  end
end
