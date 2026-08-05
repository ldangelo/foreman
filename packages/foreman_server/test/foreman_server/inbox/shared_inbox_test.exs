defmodule ForemanServer.Inbox.SharedInboxTest do
  @moduledoc """
  TRD-001: SharedInbox schema and dedupe behaviour tests.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Inbox.SharedInbox
  alias ForemanServer.Inbox.{InboxItemStarted, InboxItemDeduped, DedupeTable}

  defmodule FakeSource do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    @impl true
    def correlation_id(%{"id" => id}), do: id
    def correlation_id(%{id: id}), do: id
  end

  defmodule EmptySource do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    @impl true
    def correlation_id(_payload), do: nil
  end

  defmodule NotASource do
    def some_other_fun, do: :ok
  end

  setup do
    # NOTE: do NOT call DedupeTable.start_link/1 here — the regression test
    # (in describe "dedupe_table ownership") proves the supervised GenServer
    # is running, which is only meaningful if no test setup creates it.
    DedupeTable.clear()
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    :ok
  end

  describe "ingest/2" do
    test "first call returns :started with InboxItemStarted" do
      assert {:ok, :started, %InboxItemStarted{} = item} =
               SharedInbox.ingest(FakeSource, %{"id" => "evt-1", "body" => "hi"})

      assert item.correlation_id == "evt-1"
      assert item.source == FakeSource
      assert item.payload == %{"id" => "evt-1", "body" => "hi"}
      assert is_integer(item.timestamp)
    end

    test "second call within window returns :deduped with InboxItemDeduped" do
      payload = %{"id" => "evt-2", "body" => "hi"}

      assert {:ok, :started, _} = SharedInbox.ingest(FakeSource, payload)

      assert {:ok, :deduped, %InboxItemDeduped{} = deduped} =
               SharedInbox.ingest(FakeSource, payload)

      assert deduped.correlation_id == "evt-2"
      assert deduped.source == FakeSource
      assert deduped.existing.correlation_id == "evt-2"
    end

    test "rejects source that does not implement the behaviour" do
      assert {:error, {:unknown_source, NotASource}} =
               SharedInbox.ingest(NotASource, %{"id" => "x"})
    end

    test "rejects payload with empty correlation_id" do
      assert {:error, :no_correlation_id} =
               SharedInbox.ingest(EmptySource, %{"id" => "x"})
    end

    test "size drops back to zero after window" do
      Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 0)
      DedupeTable.clear()

      assert {:ok, :started, _} = SharedInbox.ingest(FakeSource, %{"id" => "evt-3"})
      Process.sleep(5)
      assert :miss = DedupeTable.lookup(FakeSource, "evt-3")
    end
  end

  describe "dedupe_table ownership" do
    test "is owned by the supervised GenServer, not a transient caller" do
      # Regression: the dedupe ETS table must outlive any transient caller.
      # Previously the table was lazily created inside `ensure_table/0` and
      # owned by whichever caller won the race; that caller exiting (e.g. a
      # test process) destroyed the table and broke the dedup contract.
      # The fix routes ownership through a registered GenServer started by
      # the application supervisor.
      owner = :ets.info(DedupeTable, :owner)
      assert is_pid(owner), "DedupeTable must be a named, public ETS table"

      supervised = Process.whereis(DedupeTable)

      assert is_pid(supervised),
             "DedupeTable must be a registered GenServer in the supervision tree"

      assert Process.alive?(supervised)
      assert owner == supervised, "ETS table must be owned by the supervised GenServer"
    end
  end

  describe "dedupe_window_seconds/0" do
    test "returns configured value" do
      Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 120)
      assert SharedInbox.dedupe_window_seconds() == 120
    end

    test "returns default when unset" do
      Application.delete_env(:foreman_server, :inbox_dedupe_window_seconds)
      assert SharedInbox.dedupe_window_seconds() == 300
    end
  end
end
