defmodule ForemanServer.Idempotency.CrashRecoveryRunRepositoriesTest do
  @moduledoc """
  `CrashRecovery.has_no_side_effects?/1` reads PR / worktree side effects through
  `ProjectionStore.run_repositories/1` (every repository of the run).
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.CrashRecovery
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.KeyStoreReset
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    {:ok, _pid} = KeyStore.ensure_started()
    KeyStoreReset.reset!()
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp started_key(run_id) do
    key = "key-#{run_id}"
    :ok = KeyStore.mark_started(key, %{run_id: run_id})
    key
  end

  test "no PR and no worktree: no side effects" do
    assert CrashRecovery.has_no_side_effects?(started_key("run-a"))
  end

  test "a PR association is a side effect" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "PrAssociated",
                 payload: %{run_id: "run-b", pr_url: "https://x/pull/2"}
               }
             ])

    refute CrashRecovery.has_no_side_effects?(started_key("run-b"))
  end

  test "a created secondary-repo worktree is a side effect; a cleaned one is not" do
    created = fn status_event ->
      %{
        event_type: status_event,
        payload: %{
          operation_id: "wt-run-c-api",
          project_id: "p",
          run_id: "run-c",
          phase_id: "ph",
          repo_id: "api"
        }
      }
    end

    assert :ok = ProjectionStore.apply_events([created.("WorktreeCreated")])
    refute CrashRecovery.has_no_side_effects?(started_key("run-c"))

    assert :ok = ProjectionStore.apply_events([created.("WorktreeCleaned")])
    assert CrashRecovery.has_no_side_effects?("key-run-c")
  end
end
