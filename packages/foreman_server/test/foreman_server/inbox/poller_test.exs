defmodule ForemanServer.Inbox.PollerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Inbox.{Poller, SharedInbox, InboxItemStarted, InboxItemDeduped}

  defmodule TestSource do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    def correlation_id(%{"id" => id}), do: id
    def correlation_id(%{id: id}), do: id
  end

  defmodule OtherSource do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    def correlation_id(%{"id" => id}), do: id
  end

  setup do
    case Process.whereis(Poller) do
      nil ->
        {:ok, _pid} = Poller.start_link([])

      pid ->
        if not Process.alive?(pid), do: {:ok, _pid} = Poller.start_link([])
    end

    # Clear stats from any previous test.
    try do
      :ets.delete_all_objects(:foreman_inbox_poller_stats)
    catch
      _, _ -> :ok
    end

    on_exit(fn ->
      for {source, _} <- Poller.handlers(), do: Poller.detach_handler(source)
    end)

    :ok
  end

  describe "stats/0" do
    test "returns an empty map before any events" do
      assert Poller.stats() == %{}
    end
  end

  describe "attach_handler/3 + dispatch" do
    test "attaches a handler and dispatches InboxItemStarted to the calling pid" do
      :ok = Poller.attach_handler(TestSource, :stub_handler, self())
      [{TestSource, {:stub_handler, _pid}}] = Poller.handlers()

      assert {:ok, :started, %InboxItemStarted{} = item} =
               SharedInbox.ingest(TestSource, %{
                 "id" => "poller-test-#{System.unique_integer([:positive])}"
               })

      stats = Poller.synchronize()
      assert stats.started >= 1
    end

    test "unmatched source does not crash" do
      :ok = Poller.attach_handler(TestSource, :stub_handler, self())

      assert {:ok, :started, _item} =
               SharedInbox.ingest(OtherSource, %{
                 "id" => "no-handler-#{System.unique_integer([:positive])}"
               })

      refute_receive {:inbox_item_started, _, _}, 100
    end
  end

  describe "deduped events" do
    test "InboxItemDeduped increments :deduped counter" do
      id = "dedup-#{System.unique_integer([:positive])}"
      assert {:ok, :started, _} = SharedInbox.ingest(TestSource, %{"id" => id})
      assert {:ok, :deduped, %InboxItemDeduped{}} = SharedInbox.ingest(TestSource, %{"id" => id})

      stats = Poller.synchronize()
      assert stats.deduped >= 1
    end
  end

  describe "detach_handler/1" do
    test "removes a binding" do
      :ok = Poller.attach_handler(TestSource, :stub_handler, self())
      :ok = Poller.detach_handler(TestSource)
      assert Poller.handlers() == []
    end
  end
end
