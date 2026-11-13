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

    test "lifecycle started -> failed records the reason" do
      :ok = KeyStore.mark_started("k2f", %{run_id: "r1"})
      :ok = KeyStore.mark_failed("k2f", "worker_timeout")
      assert {:ok, :failed} = KeyStore.status("k2f")

      assert {:ok, %{status: :failed, metadata: %{:run_id => "r1", "reason" => "worker_timeout"}}} =
               KeyStore.get("k2f")

      assert ["k2f"] = KeyStore.list_by_status(:failed)
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

  describe "effect_key?/1 (TRD-011)" do
    test "is true for an effect key" do
      assert KeyStore.effect_key?("effect:branch_push:run-1:feature/x")
      assert KeyStore.effect_key?("effect:task_provider:run-1:claim:issue-9")
    end

    test "is false for an agent-phase key, an empty string and a mid-string effect:" do
      refute KeyStore.effect_key?("phase:run-1:implement")
      refute KeyStore.effect_key?("")
      refute KeyStore.effect_key?("phase:effect:run-1")
      refute KeyStore.effect_key?("x-effect:branch_push:run-1:y")
      refute KeyStore.effect_key?("Effect:branch_push:run-1:y")
    end

    test "is false for a non-binary" do
      refute KeyStore.effect_key?(nil)
      refute KeyStore.effect_key?(:"effect:x")
    end
  end

  describe "fallback merge keeps its current shape" do
    setup do
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
      ForemanServer.TestSupport.KeyStoreReset.reset!()
    end

    test "a status change merges the new fields into the ETS copy" do
      :ok = KeyStore.mark_started("phase:r9:p1", %{run_id: "r9", cwd: "/w"})
      :ok = KeyStore.mark_ambiguous("phase:r9:p1", "timeout")

      assert {:ok,
              %{
                status: :ambiguous,
                metadata: %{:run_id => "r9", :cwd => "/w", "reason" => "timeout"}
              }} =
               KeyStore.get("phase:r9:p1")
    end
  end

  describe "mark_unresolved/3 (fallback)" do
    setup do
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
      ForemanServer.TestSupport.KeyStoreReset.reset!()
    end

    test "keeps the key ambiguous, merges into its metadata and is read back as a version" do
      key = "effect:branch_push:r1:feature/x"
      :ok = KeyStore.mark_started(key, %{"run_id" => "r1", "pushed_local_sha" => "abc"})
      :ok = KeyStore.mark_unresolved(key, 4, "effect_already_done")

      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)

      assert %{
               "run_id" => "r1",
               "pushed_local_sha" => "abc",
               "unresolved_reason" => "effect_already_done"
             } = metadata

      assert KeyStore.unresolved_version(metadata) == {:ok, 4}
    end

    test "unresolved_version/1 is :none without a usable marker" do
      assert KeyStore.unresolved_version(%{}) == :none
      assert KeyStore.unresolved_version(%{"unresolved_at_run_version" => nil}) == :none
      assert KeyStore.unresolved_version(nil) == :none
    end

    test "unresolved_version/1 fails closed on a marker that is present but malformed" do
      assert KeyStore.unresolved_version(%{"unresolved_at_run_version" => "4"}) ==
               {:error, :malformed}

      assert KeyStore.unresolved_version(%{"unresolved_at_run_version" => -1}) ==
               {:error, :malformed}

      # string key only: an atom-keyed marker is not one
      assert KeyStore.unresolved_version(%{unresolved_at_run_version: 4}) == :none
    end

    test "lift_unresolved/3 moves a key to started only at the observed marker; the second caller loses" do
      key = "effect:branch_push:r2:feature/y"
      :ok = KeyStore.mark_started(key, %{"run_id" => "r2"})
      assert :not_unresolved = KeyStore.lift_unresolved(key, 2, %{})

      :ok = KeyStore.mark_unresolved(key, 2, "effect_already_done")
      clear = %{"unresolved_at_run_version" => nil, "unresolved_reason" => nil}

      # a marker at another version than the one observed is not lifted
      assert :not_unresolved = KeyStore.lift_unresolved(key, 1, clear)
      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)

      assert :lifted = KeyStore.lift_unresolved(key, 2, clear)

      assert {:ok, %{status: :started, metadata: %{"run_id" => "r2"} = metadata}} =
               KeyStore.get(key)

      assert KeyStore.unresolved_version(metadata) == :none
      assert :not_unresolved = KeyStore.lift_unresolved(key, 2, clear)
      assert :not_unresolved = KeyStore.lift_unresolved("effect:branch_push:r2:absent", 2, clear)
    end
  end

  describe "the decision on an ambiguous effect key (fallback)" do
    setup do
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
      ForemanServer.TestSupport.KeyStoreReset.reset!()
    end

    test "mark_decided/2 decides an ambiguous key without a marker and keeps the rest of its metadata" do
      key = "effect:branch_push:r3:feature/z"
      ambiguous_key(key)

      assert :ok = KeyStore.mark_decided(key, :not_done)

      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)

      assert %{"run_id" => "r3", "pushed_local_sha" => "abc", "decision" => "not_done"} = metadata
      assert KeyStore.decision(metadata) == :not_done

      # deciding a decided key is not an error
      assert :ok = KeyStore.mark_decided(key, :not_done)
      assert {:ok, %{status: :ambiguous, metadata: ^metadata}} = KeyStore.get(key)
    end

    test "mark_decided/2 refuses every key that is not an ambiguous key without a marker" do
      absent = "effect:branch_push:r3:absent"
      assert :not_decidable = KeyStore.mark_decided(absent, :not_done)
      assert :not_found = KeyStore.get(absent)

      for {name, prepare} <- [
            {"started", fn key -> :ok = KeyStore.mark_started(key, %{"run_id" => "r3"}) end},
            {"completed", fn key -> :ok = KeyStore.mark_completed(key) end},
            {"failed", fn key -> :ok = KeyStore.mark_failed(key, "boom") end},
            {"unresolved",
             fn key ->
               ambiguous_key(key)
               :ok = KeyStore.mark_unresolved(key, 4, "effect_already_done")
             end}
          ] do
        key = "effect:branch_push:r3:#{name}"
        prepare.(key)
        {:ok, before_key} = KeyStore.get(key)

        assert :not_decidable = KeyStore.mark_decided(key, :not_done), name
        assert {:ok, ^before_key} = KeyStore.get(key)
      end

      # a marker that is present but malformed is not "no marker"
      malformed = "effect:branch_push:r3:malformed"
      ambiguous_key(malformed, %{"unresolved_at_run_version" => "4"})
      {:ok, before_malformed} = KeyStore.get(malformed)
      assert :not_decidable = KeyStore.mark_decided(malformed, :not_done)
      assert {:ok, ^before_malformed} = KeyStore.get(malformed)
    end

    test "a key its effect settled in the meantime is not decided on a stale read" do
      key = "effect:branch_push:r3:settled"
      ambiguous_key(key)
      :ok = KeyStore.mark_completed(key)

      assert :not_decidable = KeyStore.mark_decided(key, :not_done)
      assert {:ok, %{status: :completed, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none
    end

    test "decision/1 is :not_done only for the string-keyed value not_done" do
      assert KeyStore.decision(%{"decision" => "not_done"}) == :not_done

      for undecided <- [
            %{},
            %{"decision" => nil},
            %{"decision" => "done"},
            %{"decision" => "unknown"},
            %{"decision" => :not_done},
            %{"decision" => 1},
            %{decision: "not_done"},
            nil,
            "not_done"
          ] do
        assert KeyStore.decision(undecided) == :none, inspect(undecided)
      end
    end

    test "consume_decision/3 moves a decided key to started only while it is decided; the second caller loses" do
      key = "effect:branch_push:r4:feature/y"
      cleared = %{"decision" => nil}
      assert :not_decided = KeyStore.consume_decision(key, :not_done, cleared)
      ambiguous_key(key)
      assert :not_decided = KeyStore.consume_decision(key, :not_done, cleared)
      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)

      :ok = KeyStore.mark_decided(key, :not_done)
      assert :consumed = KeyStore.consume_decision(key, :not_done, Map.put(cleared, "cwd", "/w"))

      assert {:ok, %{status: :started, metadata: %{"run_id" => "r3", "cwd" => "/w"} = metadata}} =
               KeyStore.get(key)

      assert KeyStore.decision(metadata) == :none
      assert metadata["decision"] == nil
      assert :not_decided = KeyStore.consume_decision(key, :not_done, cleared)
    end

    test "consume_decision/3 is refused for settled, unresolved and malformed keys" do
      cleared = %{"decision" => nil}

      for {name, prepare} <- [
            {"started",
             fn key -> :ok = KeyStore.mark_started(key, %{"decision" => "not_done"}) end},
            {"completed",
             fn key -> :ok = KeyStore.mark_completed(key, %{"decision" => "not_done"}) end},
            {"failed", fn key -> :ok = KeyStore.mark_failed(key, "boom") end},
            {"unresolved",
             fn key ->
               ambiguous_key(key, %{"decision" => "not_done"})
               :ok = KeyStore.mark_unresolved(key, 4, "effect_already_done")
             end},
            {"malformed",
             fn key ->
               ambiguous_key(key, %{"decision" => "not_done", "unresolved_at_run_version" => "4"})
             end}
          ] do
        key = "effect:branch_push:r5:#{name}"
        prepare.(key)
        {:ok, before_key} = KeyStore.get(key)

        assert :not_decided = KeyStore.consume_decision(key, :not_done, cleared), name
        assert {:ok, ^before_key} = KeyStore.get(key)
      end
    end
  end

  # A key the boot sweep flipped to `ambiguous`; `extra` is written with its intent.
  defp ambiguous_key(key, extra \\ %{}) do
    intent = Map.merge(%{"run_id" => "r3", "pushed_local_sha" => "abc"}, extra)
    :ok = KeyStore.mark_started(key, intent)
    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
  end
end
