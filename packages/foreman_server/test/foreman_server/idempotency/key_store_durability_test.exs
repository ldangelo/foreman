defmodule ForemanServer.Idempotency.KeyStoreDurabilityTest do
  @moduledoc """
  TRD-014: the store reports whether it is durable (`durable?/0`, `durability/0`),
  `list_records_checked/1` reads records without hiding a failed repo behind ETS,
  and boot says so loudly when keys will not survive a restart.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Idempotency.{Effect, IdempotencyKey, KeyStore}
  alias ForemanServer.TestSupport.KeyStoreReset

  @config ForemanServer.Agents.JidoCheckpointStore
  @rows :key_store_durability_fake_repo
  @event [:foreman_server, :idempotency, :key_store, :not_durable]

  defmodule FakeRepo do
    @moduledoc false
    # Rows live in a public ETS table the test owns, so they survive a `KeyStore`
    # restart; metadata makes a JSON round trip (string keys, as from Postgres).
    # `:mode` switches the repo between answering, raising and exiting.
    @rows :key_store_durability_fake_repo

    def insert(changeset, _opts) do
      key = Ecto.Changeset.get_field(changeset, :key)
      status = Ecto.Changeset.get_field(changeset, :status)

      metadata =
        changeset |> Ecto.Changeset.get_field(:metadata) |> Jason.encode!() |> Jason.decode!()

      :ets.insert(@rows, {key, status, metadata})
      {:ok, %IdempotencyKey{key: key, status: status, metadata: metadata}}
    end

    def get(IdempotencyKey, key) do
      case :ets.lookup(@rows, key) do
        [{^key, status, metadata}] ->
          %IdempotencyKey{key: key, status: status, metadata: metadata}

        [] ->
          nil
      end
    end

    # The status the query pins (`where: k.status == ^status`), so the fake filters like a DB.
    def all(query) do
      case :ets.lookup(@rows, :mode) do
        [{:mode, :raise}] ->
          raise DBConnection.ConnectionError, "connection refused"

        [{:mode, :exit}] ->
          exit({:noproc, {DBConnection.Holder, :checkout, []}})

        _ when query.wheres == [] ->
          # The durability probe: honour `limit` and record how many rows came back.
          limit = if query.limit, do: query.limit.expr, else: :all

          keys =
            for({key, _status, _meta} <- :ets.tab2list(@rows), is_binary(key), do: key)
            |> then(&if(limit == :all, do: &1, else: Enum.take(&1, limit)))

          :ets.insert(@rows, {:probe_rows, length(keys)})
          keys

        _ ->
          [%{params: [{status, _type}]}] = query.wheres

          for {key, ^status, metadata} <- :ets.tab2list(@rows), is_binary(key) do
            %IdempotencyKey{key: key, status: status, metadata: metadata}
          end
      end
    end
  end

  setup do
    original = Application.get_env(:foreman_server, @config, [])

    if :ets.whereis(@rows) == :undefined, do: :ets.new(@rows, [:set, :public, :named_table])
    :ets.delete_all_objects(@rows)

    on_exit(fn ->
      Application.put_env(:foreman_server, @config, original)
      restart_key_store()
      KeyStoreReset.reset!()
    end)

    Application.put_env(:foreman_server, @config, [])
    restart_key_store()
    KeyStoreReset.reset!()
    :ok
  end

  defp restart_key_store do
    Supervisor.terminate_child(ForemanServer.Application, KeyStore)
    {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
    :ok
  end

  defp use_fake_repo do
    Application.put_env(:foreman_server, @config, repo: FakeRepo)
    restart_key_store()
  end

  defp repo_mode(mode), do: :ets.insert(@rows, {:mode, mode})

  defp attach_not_durable do
    {handler_id, _ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), [@event])

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "ETS fallback (no repo)" do
    test "is not durable, and the note names the production switches" do
      assert KeyStore.durability() == {:not_durable, :no_repo}
      refute KeyStore.durable?()

      note = KeyStore.durability_note()
      assert note =~ "not durable"
      assert note =~ "do not survive a restart"
      assert note =~ "FOREMAN_JIDO_ECTO_ENABLED=true"
      assert note =~ "jido_ecto"
      assert note =~ "JIDO_CHECKPOINT_DATABASE_URL"
    end

    test "list_records_checked/1 scans the ETS table by status" do
      :ok = KeyStore.mark_started("k-a", %{"run_id" => "r1"})
      :ok = KeyStore.mark_ambiguous("k-a", "expired")
      :ok = KeyStore.mark_started("k-b", %{"run_id" => "r2"})

      assert {:ok, [%{key: "k-a", status: :ambiguous, metadata: meta}]} =
               KeyStore.list_records_checked(:ambiguous)

      assert meta["run_id"] == "r1"
      assert meta[:reason] == "expired"
    end

    test "an effect still runs and records its intent, and a restart then loses the key" do
      key = Effect.key("branch_push", "run-1", "feature/x")
      test = self()

      assert :pushed ==
               Effect.run(
                 "branch_push",
                 key,
                 fn ->
                   send(test, :effect_ran)
                   :pushed
                 end,
                 %{"run_id" => "run-1", "head_branch" => "feature/x", "cwd" => "/tmp"}
               )

      assert_received :effect_ran
      assert {:ok, :completed} = KeyStore.status(key)

      # A crash mid-effect leaves `started`; the restart empties the table, so the
      # sweep (which reads `list_by_status/1`) finds nothing to reconcile.
      :ok = KeyStore.mark_started(key, %{"run_id" => "run-1"})
      restart_key_store()

      assert KeyStore.list_by_status(:started) == []
      assert KeyStore.list_by_status(:ambiguous) == []
      assert KeyStore.status(key) == :not_found
    end

    test "boot report logs an error and emits telemetry (reason no_repo)" do
      attach_not_durable()

      log =
        capture_log(fn -> assert {:not_durable, :no_repo} = KeyStore.report_boot_durability() end)

      assert log =~ "[error]"
      assert log =~ "not durable"
      assert_received {@event, _ref, %{count: 1}, %{reason: :no_repo}}
    end
  end

  describe "repo configured" do
    setup do
      use_fake_repo()
    end

    test "is durable only when the repo answers; the store line is silent" do
      assert KeyStore.durability() == :durable
      assert KeyStore.durable?()
      assert KeyStore.durability_note() == nil

      attach_not_durable()
      log = capture_log(fn -> assert :durable = KeyStore.report_boot_durability() end)

      refute log =~ "not durable"
      refute_received {@event, _, _, _}
    end

    test "list_records_checked/1 reads stored rows after a restart, filtered by status, string-keyed" do
      :ok = KeyStore.mark_started("k-a", %{run_id: "r1", effect_class: "pr_create"})
      :ok = KeyStore.mark_ambiguous("k-a", "boot")
      :ok = KeyStore.mark_started("k-b", %{run_id: "r2"})
      :ok = KeyStore.mark_completed("k-b", %{})
      restart_key_store()

      assert {:ok, [record]} = KeyStore.list_records_checked(:ambiguous)
      assert %{key: "k-a", status: :ambiguous} = record

      assert %{"run_id" => "r1", "effect_class" => "pr_create", "reason" => "boot"} =
               record.metadata
    end

    test "the durability probe reads one row, not every ambiguous record" do
      for n <- 1..3 do
        :ok = KeyStore.mark_started("k-#{n}", %{run_id: "r#{n}"})
        :ok = KeyStore.mark_ambiguous("k-#{n}", "boot")
      end

      assert KeyStore.durable?()
      assert [{:probe_rows, 1}] = :ets.lookup(@rows, :probe_rows)
      assert {:ok, records} = KeyStore.list_records_checked(:ambiguous)
      assert length(records) == 3
    end

    test "a repo that raises is unreachable: an error, never the ETS copy" do
      :ok = KeyStore.mark_started("k-a", %{run_id: "r1"})
      :ok = KeyStore.mark_ambiguous("k-a", "boot")
      assert [{"k-a", :ambiguous, _}] = :ets.lookup(:foreman_idempotency_keys, "k-a")

      repo_mode(:raise)

      assert {:error, %DBConnection.ConnectionError{}} = KeyStore.list_records_checked(:ambiguous)

      assert {:not_durable, {:unreachable, %DBConnection.ConnectionError{}}} =
               KeyStore.durability()

      refute KeyStore.durable?()

      # Boot's read is deliberately unchanged: it still falls back to the ETS keys.
      assert KeyStore.list_by_status(:ambiguous) == ["k-a"]
    end

    test "a repo that exits is unreachable too" do
      repo_mode(:exit)

      assert {:error, {:exit, _}} = KeyStore.list_records_checked(:ambiguous)
      assert {:not_durable, {:unreachable, {:exit, _}}} = KeyStore.durability()
      assert KeyStore.durability_note() =~ "configured but unreachable"
    end

    test "boot report: configured but unreachable is an error and telemetry with reason unreachable" do
      repo_mode(:raise)
      attach_not_durable()

      log =
        capture_log(fn ->
          assert {:not_durable, {:unreachable, _}} = KeyStore.report_boot_durability()
        end)

      assert log =~ "[error]"
      assert log =~ "configured but unreachable"
      assert log =~ "FOREMAN_JIDO_ECTO_ENABLED=true"
      assert_received {@event, _ref, %{count: 1}, %{reason: :unreachable}}
    end
  end

  describe "KeyStore not running" do
    test "reads report an error instead of crashing the caller" do
      Supervisor.terminate_child(ForemanServer.Application, KeyStore)

      try do
        assert {:error, {:exit, _}} = KeyStore.list_records_checked(:ambiguous)
        assert {:not_durable, {:unreachable, {:exit, _}}} = KeyStore.durability()
        refute KeyStore.durable?()
      after
        {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
      end
    end
  end
end
