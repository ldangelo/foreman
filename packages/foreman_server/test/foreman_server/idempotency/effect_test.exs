defmodule ForemanServer.Idempotency.EffectTest do
  @moduledoc """
  `ForemanServer.Idempotency.Effect` (TRD-011): intent is recorded before the
  effect, the outcome after, an unrecordable intent refuses the effect, and an
  effect interrupted by a restart leaves a key boot reconciliation can find.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.IdempotencyKey
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.TestSupport.KeyStoreReset
  alias ForemanServer.Workflow.BootReconciliation

  @config ForemanServer.Agents.JidoCheckpointStore
  @table :foreman_idempotency_keys
  @run_id "run-effect-test"

  defmodule FakeRepo do
    @moduledoc false
    # Rows live in a public ETS table the test owns, so they survive a
    # `KeyStore` restart. Metadata makes a JSON round trip on write, so it
    # comes back with string keys exactly as it does from Postgres.
    @rows :effect_test_fake_repo

    def insert(changeset, _opts) do
      if :ets.lookup(@rows, :fail_insert) != [] do
        {:error, :db_down}
      else
        key = Ecto.Changeset.get_field(changeset, :key)
        status = Ecto.Changeset.get_field(changeset, :status)
        metadata = changeset |> Ecto.Changeset.get_field(:metadata) |> json_round_trip()
        :ets.insert(@rows, {key, status, metadata})
        {:ok, %IdempotencyKey{key: key, status: status, metadata: metadata}}
      end
    end

    def get(IdempotencyKey, key) do
      case :ets.lookup(@rows, key) do
        [{^key, status, metadata}] ->
          %IdempotencyKey{key: key, status: status, metadata: metadata}

        [] ->
          nil
      end
    end

    def all(_query),
      do: for({key, _status, _meta} <- :ets.tab2list(@rows), is_binary(key), do: key)

    defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
  end

  setup do
    original = Application.get_env(:foreman_server, @config, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, @config, original)
      restart_key_store()
    end)

    Application.put_env(:foreman_server, @config, [])
    KeyStoreReset.reset!()
    :ok
  end

  defp restart_key_store do
    Supervisor.terminate_child(ForemanServer.Application, KeyStore)
    {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
    :ok
  end

  defp use_fake_repo do
    if :ets.whereis(:effect_test_fake_repo) == :undefined do
      :ets.new(:effect_test_fake_repo, [:set, :public, :named_table])
    end

    Application.put_env(:foreman_server, @config, repo: FakeRepo)
    restart_key_store()
  end

  defp push_meta(extra \\ %{}) do
    Map.merge(
      %{run_id: @run_id, head_branch: "feature/x", cwd: "/work/tree"},
      extra
    )
  end

  defp push_key(branch \\ "feature/x"), do: Effect.key(:branch_push, @run_id, branch)

  describe "run/4 ordering and outcome" do
    test "the started key, with its typed metadata, exists before the effect runs" do
      key = push_key()
      test_pid = self()

      result =
        Effect.run(
          :branch_push,
          key,
          fn ->
            send(test_pid, {:inside, KeyStore.get(key)})
            {:ok, :pushed}
          end,
          push_meta()
        )

      assert {:ok, :pushed} = result

      assert_received {:inside, {:ok, %{status: :started, metadata: metadata}}}

      assert %{
               "run_id" => @run_id,
               "effect_class" => "branch_push",
               "head_branch" => "feature/x",
               "cwd" => "/work/tree"
             } = metadata

      refute Enum.any?(Map.keys(metadata), &is_atom/1)
    end

    test "success marks the key completed and returns the result unchanged" do
      key = push_key()
      assert :pushed == Effect.run(:branch_push, key, fn -> :pushed end, push_meta())

      assert {:ok, %{status: :completed, metadata: %{"run_id" => @run_id}}} = KeyStore.get(key)
    end

    test "an error result marks the key failed and is returned unchanged" do
      key = push_key()

      assert {:error, :rejected} ==
               Effect.run(:branch_push, key, fn -> {:error, :rejected} end, push_meta())

      assert {:ok, %{status: :failed, metadata: %{"run_id" => @run_id, reason: reason}}} =
               KeyStore.get(key)

      assert reason =~ "rejected"
    end

    test "a raising effect marks the key failed and the exception propagates" do
      key = push_key()

      assert_raise RuntimeError, "boom", fn ->
        Effect.run(:branch_push, key, fn -> raise "boom" end, push_meta())
      end

      assert {:ok, %{status: :failed}} = KeyStore.get(key)
    end

    test "the key is derived from stable identity" do
      assert Effect.key(:pr_create, "r1", "feat:main") == "effect:pr_create:r1:feat:main"

      assert Effect.key(:pr_create, "r1", "feat:main") ==
               Effect.key("pr_create", "r1", "feat:main")
    end
  end

  describe "run/4 refusal" do
    test "a push without cwd records no intent and does not run" do
      key = push_key()
      test_pid = self()

      assert {:error, {:intent_not_recorded, :cwd_missing}} =
               Effect.run(
                 :branch_push,
                 key,
                 fn -> send(test_pid, :ran) end,
                 Map.delete(push_meta(), :cwd)
               )

      refute_received :ran
      assert :not_found = KeyStore.get(key)
    end

    test "metadata without a run_id is refused" do
      key = push_key()

      assert {:error, {:intent_not_recorded, {:missing_metadata, "run_id"}}} =
               Effect.run(:branch_push, key, fn -> :ran end, Map.delete(push_meta(), :run_id))

      assert :not_found = KeyStore.get(key)
    end

    test "a key that is not an effect key of the class is refused" do
      assert {:error, {:intent_not_recorded, :invalid_key}} =
               Effect.run(:branch_push, "phase:#{@run_id}:p1", fn -> :ran end, push_meta())

      assert {:error, {:intent_not_recorded, :invalid_key}} =
               Effect.run(
                 :branch_push,
                 Effect.key(:pr_create, @run_id, "x"),
                 fn -> :ran end,
                 push_meta()
               )
    end

    test "a key that cannot be written means the effect is not called" do
      use_fake_repo()
      :ets.insert(:effect_test_fake_repo, {:fail_insert, true, %{}})
      test_pid = self()

      assert {:error, {:intent_not_recorded, :db_down}} =
               Effect.run(:branch_push, push_key(), fn -> send(test_pid, :ran) end, push_meta())

      refute_received :ran
    end
  end

  describe "crash mid-effect" do
    test "boot marks the started key ambiguous when its run is not live (ETS path)" do
      key = push_key()
      test_pid = self()

      pid =
        spawn(fn ->
          Effect.run(
            :branch_push,
            key,
            fn ->
              send(test_pid, :in_effect)
              Process.sleep(:infinity)
            end,
            push_meta()
          )
        end)

      assert_receive :in_effect
      Process.exit(pid, :kill)
      assert {:ok, :started} = KeyStore.status(key)

      BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert metadata["run_id"] == @run_id
      assert metadata[:reason] == "orphaned_started_key"
    end

    test "with no repo, an emptied table leaves nothing to reconcile and raises nothing" do
      key = push_key()
      :ok = Effect.run(:branch_push, key, fn -> :ok end, push_meta())
      :ets.delete_all_objects(@table)

      assert [] = KeyStore.list_by_status(:started)
      BootReconciliation.do_reconcile_ambiguous_keys()
      assert :not_found = KeyStore.get(key)
    end

    test "on the repo path every field written survives a restart and the sweep" do
      use_fake_repo()
      key = push_key()
      test_pid = self()

      meta =
        push_meta(%{pre_push_remote_sha: "aaa111", pushed_local_sha: "bbb222"})

      pid =
        spawn(fn ->
          Effect.run(
            :branch_push,
            key,
            fn ->
              send(test_pid, :in_effect)
              Process.sleep(:infinity)
            end,
            meta
          )
        end)

      assert_receive :in_effect
      Process.exit(pid, :kill)

      # The restart drops the ETS table; the fake repo's rows remain.
      restart_key_store()
      assert [] = :ets.lookup(@table, key)

      BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)

      assert %{
               "run_id" => @run_id,
               "effect_class" => "branch_push",
               "head_branch" => "feature/x",
               "cwd" => "/work/tree",
               "pre_push_remote_sha" => "aaa111",
               "pushed_local_sha" => "bbb222",
               "reason" => "orphaned_started_key"
             } = metadata
    end
  end
end
