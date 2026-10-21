defmodule ForemanServer.DispatcherQuiesceTest do
  use ExUnit.Case, async: false

  alias ForemanServer.DispatcherQuiesce

  defmodule Busy do
    use GenServer

    def init(_), do: {:ok, nil}

    # Stuck inside a message until told to continue.
    def handle_info(:block, state) do
      receive do
        :go -> {:noreply, state}
      end
    end
  end

  test "a suspend that times out is still undone when the test exits" do
    {:ok, pid} = GenServer.start(Busy, nil)
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

  test "resume tolerates a target that died while suspended" do
    {:ok, pid} = GenServer.start(Busy, nil)
    :ok = DispatcherQuiesce.suspend!(pid: pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
