defmodule ForemanServer.DispatcherQuiesceTest do
  use ExUnit.Case, async: false

  alias ForemanServer.DispatcherQuiesce

  defmodule Busy do
    use GenServer

    def init(notify) do
      Process.put(:notify, notify)
      {:ok, nil}
    end

    # Stuck inside a message until told to continue.
    def handle_info(:block, state) do
      send(Process.get(:notify), {:blocked, self()})

      receive do
        :go -> {:noreply, state}
      end
    end
  end

  test "a suspend that times out is still undone when the test exits" do
    {:ok, pid} = GenServer.start(Busy, self())
    send(pid, :block)

    # Registered first => runs last, i.e. after DispatcherQuiesce's resume.
    on_exit(fn ->
      status = :sys.get_status(pid)
      Process.exit(pid, :kill)
      assert {:status, ^pid, _, [_, :running | _]} = status
    end)

    assert catch_exit(DispatcherQuiesce.suspend!(pid: pid, timeout: 50))

    # Unblock the target: it now consumes the queued suspend request and
    # parks itself, which only the on_exit resume can undo.
    send(pid, :go)
    assert {:status, ^pid, _, [_, :suspended | _]} = :sys.get_status(pid, 5_000)
  end

  test "cleanup does not fail when the target is still busy at resume time" do
    {:ok, pid} = GenServer.start(Busy, self())

    # Registered first => runs last, after DispatcherQuiesce's resume.
    on_exit(fn ->
      send(pid, :go)
      Process.exit(pid, :kill)
    end)

    send(pid, :block)
    assert_receive {:blocked, ^pid}

    # Target is stuck inside :block, so both the suspend and the on_exit resume
    # time out.
    assert catch_exit(DispatcherQuiesce.suspend!(pid: pid, timeout: 50, resume_timeout: 50))
  end

  test "resume tolerates a target that died while suspended" do
    {:ok, pid} = GenServer.start(Busy, self())
    :ok = DispatcherQuiesce.suspend!(pid: pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
