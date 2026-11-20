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

  describe "mark_failed/3 metadata keys" do
    defp assert_failed_reason(key) do
      assert {:ok, [%{key: ^key, status: :failed, metadata: meta}]} =
               KeyStore.list_records_checked(:failed)

      assert meta["reason"] == "boom"
      assert meta["unresolved_reason"] == nil
      assert Map.has_key?(meta, "decision")
      refute Map.has_key?(meta, :reason)
    end

    test "the ETS path stores a string-keyed reason, atom-keyed meta included" do
      :ok = KeyStore.mark_started("k-f", %{run_id: "r1"})
      :ok = KeyStore.mark_failed("k-f", "boom", KeyStore.recovery_fields_cleared())
      assert_failed_reason("k-f")
    end

    test "the repo path reads the same key after a restart" do
      use_fake_repo()
      :ok = KeyStore.mark_started("k-f", %{run_id: "r1"})
      :ok = KeyStore.mark_failed("k-f", "boom", KeyStore.recovery_fields_cleared())
      assert_failed_reason("k-f")
      restart_key_store()
      assert_failed_reason("k-f")
    end
  end

  describe "mark_ambiguous/2 and mark_unresolved/3 are compare-and-set (foreman-ulg5y.3.12)" do
    for {name, setup_repo} <- [{"the ETS path", false}, {"the repo path", true}] do
      test "#{name}: a late verdict after the effect settled leaves the key settled" do
        if unquote(setup_repo), do: use_fake_repo()

        :ok = KeyStore.mark_started("k-late", %{"run_id" => "r1", "effect_class" => "pr_create"})
        :ok = KeyStore.mark_completed("k-late", %{"pr" => 7})

        assert :status_changed = KeyStore.mark_ambiguous("k-late", "orphaned_started_key")
        assert :status_changed = KeyStore.mark_unresolved("k-late", 4, "effect_already_done")
        assert {:ok, :completed} = KeyStore.status("k-late")
        assert {:ok, %{metadata: meta}} = KeyStore.get("k-late")
        assert KeyStore.unresolved_version(meta) == :none
        refute Map.has_key?(meta, "reason")

        :ok = KeyStore.mark_started("k-fail", %{"run_id" => "r1"})
        :ok = KeyStore.mark_failed("k-fail", "boom")
        assert :status_changed = KeyStore.mark_ambiguous("k-fail", "late")
        assert {:ok, :failed} = KeyStore.status("k-fail")
      end

      test "#{name}: started -> ambiguous -> marked works and the reason is a string key" do
        if unquote(setup_repo), do: use_fake_repo()

        :ok = KeyStore.mark_started("k-ok", %{"run_id" => "r1", "effect_class" => "pr_create"})
        assert :ok = KeyStore.mark_ambiguous("k-ok", "orphaned_started_key")
        assert {:ok, :ambiguous} = KeyStore.status("k-ok")
        assert {:ok, %{metadata: meta}} = KeyStore.get("k-ok")
        assert meta["reason"] == "orphaned_started_key"
        refute Map.has_key?(meta, :reason)
        assert meta["run_id"] == "r1"

        assert :ok = KeyStore.mark_unresolved("k-ok", 3, "effect_outcome_ambiguous")
        assert {:ok, %{metadata: meta}} = KeyStore.get("k-ok")
        assert KeyStore.unresolved_version(meta) == {:ok, 3}
        assert {:ok, :ambiguous} = KeyStore.status("k-ok")
      end

      test "#{name}: an absent key can be marked ambiguous (a first write), but not unresolved" do
        if unquote(setup_repo), do: use_fake_repo()

        assert :ok = KeyStore.mark_ambiguous("k-new", "heartbeat_timeout")
        assert {:ok, :ambiguous} = KeyStore.status("k-new")
        assert :status_changed = KeyStore.mark_unresolved("k-gone", 1, "x")
        assert :not_found = KeyStore.get("k-gone")
      end
    end
  end

  describe "mark_completed/2 and mark_failed/3 are compare-and-set (PR 4 opening commit)" do
    for {name, setup_repo} <- [{"the ETS path", false}, {"the repo path", true}] do
      test "#{name}: a settled key is never rewritten by either writer" do
        if unquote(setup_repo), do: use_fake_repo()

        :ok = KeyStore.mark_started("k-done", %{"run_id" => "r1"})
        :ok = KeyStore.mark_completed("k-done", %{"pr" => 7})
        assert :status_changed = KeyStore.mark_failed("k-done", "late failure")
        assert :status_changed = KeyStore.mark_completed("k-done", %{"pr" => 8})
        assert {:ok, %{status: :completed, metadata: meta}} = KeyStore.get("k-done")
        assert meta["pr"] == 7
        refute Map.has_key?(meta, "reason")

        :ok = KeyStore.mark_started("k-bad", %{"run_id" => "r1"})
        :ok = KeyStore.mark_failed("k-bad", "boom")
        assert :status_changed = KeyStore.mark_completed("k-bad", %{"pr" => 9})
        assert :status_changed = KeyStore.mark_failed("k-bad", "again")
        assert {:ok, %{status: :failed, metadata: meta}} = KeyStore.get("k-bad")
        assert meta["reason"] == "boom"
        refute Map.has_key?(meta, "pr")
      end

      test "#{name}: a started or ambiguous key settles" do
        if unquote(setup_repo), do: use_fake_repo()

        :ok = KeyStore.mark_started("k-s1", %{"run_id" => "r1"})
        assert :ok = KeyStore.mark_completed("k-s1", %{})
        assert {:ok, :completed} = KeyStore.status("k-s1")

        :ok = KeyStore.mark_started("k-s2", %{"run_id" => "r1"})
        :ok = KeyStore.mark_ambiguous("k-s2", "heartbeat_timeout")
        assert :ok = KeyStore.mark_failed("k-s2", "boom")
        assert {:ok, :failed} = KeyStore.status("k-s2")
      end

      test "#{name}: a status the store never writes answers a typed error from every writer and is left as it is" do
        if unquote(setup_repo), do: use_fake_repo()

        plant_weird("k-weird")

        assert {:error, {:unexpected_status, :weird}} = KeyStore.mark_completed("k-weird", %{})
        assert {:error, {:unexpected_status, :weird}} = KeyStore.mark_failed("k-weird", "x")
        assert {:error, {:unexpected_status, :weird}} = KeyStore.mark_ambiguous("k-weird", "x")

        assert {:error, {:unexpected_status, :weird}} =
                 KeyStore.mark_unresolved("k-weird", 1, "x")

        assert {:ok, :weird} = KeyStore.status("k-weird")
      end
    end
  end

  defp plant_weird(key) do
    if :ets.whereis(@rows) != :undefined and Application.get_env(:foreman_server, @config)[:repo],
      do: :ets.insert(@rows, {key, :weird, %{}}),
      else: :ets.insert(:foreman_idempotency_keys, {key, :weird, %{}})
  end

  describe "ETS fallback (no repo)" do
    test "is not durable, and the note names the production switches" do
      assert KeyStore.durability() == {:not_durable, :no_repo}
      refute KeyStore.durable?()

      note = KeyStore.durability_note()
      assert note =~ "not durable"
      assert note =~ "do not survive a restart"
      assert note =~ "enabled: true"
      refute note =~ "FOREMAN_JIDO_ECTO_ENABLED"
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
      assert meta["reason"] == "expired"
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
      # sweep (which reads `list_records_checked/1`) finds nothing to reconcile; the ETS-only
      # `list_by_status/1` agrees.
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

      # `list_by_status/1` (no production caller; boot reads the checked list above) still
      # falls back to the ETS keys.
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
      assert log =~ "enabled: true"
      refute log =~ "FOREMAN_JIDO_ECTO_ENABLED"
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

  describe "require_durable/0 (P-3: the gating guard)" do
    @switch :require_durable_store_for_gating

    setup do
      original = Application.fetch_env(:foreman_server, @switch)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:foreman_server, @switch, value)
          :error -> Application.delete_env(:foreman_server, @switch)
        end
      end)

      Application.put_env(:foreman_server, @switch, true)
      :ok
    end

    test "required and ETS-only: refused, and the note names the production switches" do
      assert {:error, {:store_not_durable, note}} = KeyStore.require_durable()
      assert note == KeyStore.durability_note()
      assert note =~ "`config :foreman_server, :jido_ecto, enabled: true`"
      assert note =~ "JIDO_CHECKPOINT_DATABASE_URL"
      assert note =~ "no repo is configured"
    end

    test "required and the repo answers: ok" do
      use_fake_repo()
      assert KeyStore.durable?()
      assert :ok = KeyStore.require_durable()
    end

    test "required and the repo is unreachable: refused with the unreachable note, not no_repo" do
      use_fake_repo()
      repo_mode(:raise)

      assert {:error, {:store_not_durable, note}} = KeyStore.require_durable()
      assert note =~ "configured but unreachable"
      refute note =~ "no repo is configured"
      assert note =~ "JIDO_CHECKPOINT_DATABASE_URL"
    end

    test "required and the KeyStore is not running: refused, never a crash" do
      Supervisor.terminate_child(ForemanServer.Application, KeyStore)

      try do
        assert {:error, {:store_not_durable, note}} = KeyStore.require_durable()
        assert note =~ "configured but unreachable"
      after
        {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
      end
    end

    test "switch off: ok whatever the store" do
      Application.put_env(:foreman_server, @switch, false)

      refute KeyStore.durable_store_required?()
      assert :ok = KeyStore.require_durable()

      use_fake_repo()
      repo_mode(:raise)
      refute KeyStore.durable?()
      assert :ok = KeyStore.require_durable()
    end

    test "a switch that is not a boolean is read as on and refused with a note naming it, never a raise" do
      Application.put_env(:foreman_server, @switch, "false")

      assert {:error, {:store_not_durable, note}} = KeyStore.require_durable()
      assert note =~ "must be a boolean"
      assert note =~ ~s("false")
      assert note =~ KeyStore.durability_note()

      # the predicate keeps raising: only require_durable/0 is total
      assert_raise ArgumentError, ~r/must be a boolean/, fn ->
        KeyStore.durable_store_required?()
      end

      use_fake_repo()
      assert :ok = KeyStore.require_durable()
    end
  end

  describe "the shipped configuration (config.exs + dev.exs / test.exs / prod.exs)" do
    @config_dir Path.expand("../../../config", __DIR__)

    defp shipped(env) do
      [foreman_server: opts] =
        @config_dir
        |> Path.join("config.exs")
        |> Config.Reader.read!(env: env, target: :host)
        |> Keyword.take([:foreman_server])

      opts
    end

    test "development sets the switch to false: gating there is not refused store_not_durable" do
      opts = shipped(:dev)
      assert Keyword.fetch!(opts, @switch) == false
      assert Keyword.fetch!(opts, :jido_ecto) == [enabled: false]
    end

    test "test sets the switch to false" do
      assert Keyword.fetch!(shipped(:test), @switch) == false
    end

    test "production keeps the switch true and the durable store off by default" do
      opts = shipped(:prod)
      assert Keyword.fetch!(opts, @switch) == true
      assert Keyword.fetch!(opts, :jido_ecto) == [enabled: false]
    end
  end
end
