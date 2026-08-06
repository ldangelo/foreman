defmodule ForemanServer.TaskProviders.ConcurrencyLimiterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.ConcurrencyLimiter

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      previous_config
      |> Keyword.put(:max_in_flight, 4)
      |> Keyword.put(:timeout_ms, 30_000)
    )

    start_supervised!(ConcurrencyLimiter)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
    end)

    :ok
  end

  test "4 concurrent acquires succeed" do
    project_id = make_ref()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn -> ConcurrencyLimiter.acquire(project_id) end)
      end)
      |> Enum.map(&Task.await(&1, 500))

    assert results == [:ok, :ok, :ok, :ok]

    release_slots(project_id, 4)
  end

  test "5th acquire with timeout triggers BR_TIMEOUT_QUEUE" do
    project_id = make_ref()

    fill_slots(project_id, 4)

    assert {:error, :timeout} = ConcurrencyLimiter.acquire(project_id, 50)

    release_slots(project_id, 4)
  end

  test "release/1 frees a slot" do
    project_id = make_ref()
    parent = self()

    fill_slots(project_id, 4)

    waiting_acquire =
      Task.async(fn ->
        send(parent, :waiting_acquire_started)
        ConcurrencyLimiter.acquire(project_id, 200)
      end)

    assert_receive :waiting_acquire_started, 100
    Process.sleep(25)

    assert :ok = ConcurrencyLimiter.release(project_id)
    assert Task.await(waiting_acquire, 500) == :ok

    release_slots(project_id, 4)
  end

  test "per-call timeout is independent of acquire timeout" do
    project_id = make_ref()

    fill_slots(project_id, 4)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = ConcurrencyLimiter.acquire(project_id, 100)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 80
    assert elapsed_ms < 1_000

    release_slots(project_id, 4)
  end

  defp fill_slots(project_id, count) do
    Enum.each(1..count, fn _ ->
      assert :ok = ConcurrencyLimiter.acquire(project_id)
    end)
  end

  defp release_slots(project_id, count) do
    Enum.each(1..count, fn _ ->
      assert :ok = ConcurrencyLimiter.release(project_id)
    end)
  end
end
