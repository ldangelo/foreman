defmodule ForemanServer.Idempotency.EffectWriterStampTest do
  @moduledoc """
  The writer stamp `Effect.run/4` puts on a `started` key (foreman-ulg5y.3.11): the server
  incarnation and the pid of the calling process, as strings. It survives the repo-backed
  path's JSON round trip, `writer_state/1` reads it without ever raising, and a settle clears
  it.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.{Effect, IdempotencyKey, KeyStore}
  alias ForemanServer.Incarnation
  alias ForemanServer.TestSupport.KeyStoreReset

  @config ForemanServer.Agents.JidoCheckpointStore
  @rows :effect_writer_stamp_fake_repo

  defmodule FakeRepo do
    @moduledoc false
    # Rows make a JSON round trip, as from Postgres: string keys, nothing else.
    @rows :effect_writer_stamp_fake_repo

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

    def all(query) do
      [%{params: [{status, _type}]}] = query.wheres

      for {key, ^status, metadata} <- :ets.tab2list(@rows), is_binary(key) do
        %IdempotencyKey{key: key, status: status, metadata: metadata}
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

  defp meta(run_id), do: %{run_id: run_id, head_branch: "feature/s", cwd: "/w"}
  defp pid_text(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  describe "the stamp" do
    test "the started key carries this incarnation and the calling process; the effect runs in that process" do
      key = Effect.key(:branch_push, "run-stamp-1", "feature/s")
      me = self()

      assert :ran ==
               Effect.run(
                 :branch_push,
                 key,
                 fn ->
                   assert {:ok, %{status: :started, metadata: stamped}} = KeyStore.get(key)
                   assert stamped["writer_incarnation"] == Incarnation.id()
                   assert stamped["writer_pid"] == pid_text(me)
                   assert self() == me
                   assert Effect.writer_state(stamped) == :alive
                   :ran
                 end,
                 meta("run-stamp-1")
               )
    end

    test "a settle clears it, completed or failed" do
      for {result, status} <- [{:ok, :completed}, {{:error, :boom}, :failed}] do
        key = Effect.key(:branch_push, "run-stamp-#{status}", "feature/s")
        Effect.run(:branch_push, key, fn -> result end, meta("run-stamp-#{status}"))

        assert {:ok, %{status: ^status, metadata: settled}} = KeyStore.get(key)
        assert settled["writer_incarnation"] == nil
        assert settled["writer_pid"] == nil
        assert Effect.writer_state(settled) == :none
      end
    end

    test "a re-mark after a crash writes a fresh stamp over the dead writer's" do
      key = Effect.key(:branch_push, "run-stamp-re", "feature/s")

      :ok =
        KeyStore.mark_started(key, %{
          "run_id" => "run-stamp-re",
          "effect_class" => "branch_push",
          "writer_incarnation" => Incarnation.id(),
          "writer_pid" => "<0.0.0>",
          "decision" => "not_done"
        })

      :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
      :ok = KeyStore.mark_decided(key, :not_done)

      Effect.run(
        :branch_push,
        key,
        fn ->
          assert {:ok, %{metadata: now}} = KeyStore.get(key)
          assert now["writer_pid"] == pid_text(self())
          assert Effect.writer_state(now) == :alive
          :ran
        end,
        meta("run-stamp-re")
      )
    end

    test "it survives the repo-backed path's JSON round trip, restart included" do
      use_fake_repo()
      key = Effect.key(:branch_push, "run-stamp-repo", "feature/s")
      test = self()

      writer =
        spawn(fn ->
          Effect.run(
            :branch_push,
            key,
            fn ->
              send(test, {:in_effect, self()})
              Process.sleep(:infinity)
            end,
            meta("run-stamp-repo")
          )
        end)

      assert_receive {:in_effect, ^writer}
      restart_key_store()

      assert {:ok, [%{key: ^key, metadata: stored}]} = KeyStore.list_records_checked(:started)
      assert stored["writer_pid"] == pid_text(writer)
      assert Effect.writer_state(stored) == :alive

      ref = Process.monitor(writer)
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^writer, _}
      assert Effect.writer_state(stored) == :dead
    end
  end

  describe "writer_state/1" do
    test "an unstamped or partial stamp is :none" do
      assert Effect.writer_state(%{}) == :none
      assert Effect.writer_state(%{"run_id" => "r"}) == :none
      assert Effect.writer_state(%{"writer_pid" => pid_text(self())}) == :none
      assert Effect.writer_state(%{"writer_incarnation" => nil, "writer_pid" => nil}) == :none
      assert Effect.writer_state(nil) == :none
    end

    test "another incarnation is dead even when the pid is a live one of this VM" do
      stamp = %{"writer_incarnation" => "an-earlier-boot", "writer_pid" => pid_text(self())}
      assert Effect.writer_state(stamp) == :dead
    end

    test "a pid text that cannot be read back is dead, never a raise" do
      for text <- ["", "nonsense", "<0.1>", "#PID<0.1.0>", "<0.1.0>junk", "<0.99999999.0>x"] do
        stamp = %{"writer_incarnation" => Incarnation.id(), "writer_pid" => text}
        assert Effect.writer_state(stamp) == :dead, text
      end
    end

    test "a pid that is not a binary is not a stamp" do
      stamp = %{"writer_incarnation" => Incarnation.id(), "writer_pid" => 42}
      assert Effect.writer_state(stamp) == :none
    end
  end
end
