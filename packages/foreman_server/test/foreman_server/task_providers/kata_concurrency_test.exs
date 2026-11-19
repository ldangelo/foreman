defmodule ForemanServer.TaskProviders.KataConcurrencyTest do
  @moduledoc """
  TRD-KATA-T024-TEST (AC-009-2), T023 and T025 (AC-009-1): every `kata` runner call `KataAdapter`
  makes holds one slot of the application's `ConcurrencyLimiter`, keyed by the project's working
  directory. At most four calls per project are in flight, a fifth waits, a caller that cannot get
  a slot in time receives the retryable `BR_TIMEOUT_QUEUE`, and the slot is returned on success,
  on a runner failure and on a raise.

  Every test drives the production path: `KataAdapter` -> the limiter the application supervises
  -> `KataRunnerMock`. The limiter is never started or replaced here, only restarted under its
  supervisor to empty its slot table.
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ConcurrencyLimiter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TestSupport.Eventually

  @lib_root Path.expand("../../../lib", __DIR__)
  @cwd "/projects/kata-concurrency-a"
  @other_cwd "/projects/kata-concurrency-b"
  @changed_envelope ~s({"kata_api_version": 1, "changed": true})

  # The only modules that may name the limiter: itself, the telemetry catalogue it emits to,
  # the application that supervises it, and the one adapter that acquires from it.
  @limiter_references [
    "foreman_server/application.ex",
    "foreman_server/task_provider/telemetry.ex",
    "foreman_server/task_providers/concurrency_limiter.ex",
    "foreman_server/task_providers/kata_adapter.ex"
  ]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      System.put_env("PATH", original_path)
      restart_limiter!()
    end)

    restart_limiter!()
    :ok
  end

  describe "AC-009-1: at most four calls per project are in flight" do
    test "four callers run at once and a fifth waits for a slot instead of starting a process" do
      stub_blocking_runner()

      callers = start_callers(@cwd, 4)
      runners = collect_started(4)

      assert limiter_state().in_flight == %{@cwd => 4}

      fifth = start_callers(@cwd, 1, 5)
      await_waiters(1)

      refute_receive {:runner_started, _pid, _argv, _cwd}, 150
      assert limiter_state().in_flight == %{@cwd => 4}

      finish(hd(runners))
      [fifth_runner] = collect_started(1)
      finish(fifth_runner)
      Enum.each(tl(runners), &finish/1)

      assert Enum.map(callers ++ fifth, &Task.await(&1, 5_000)) == List.duplicate(:ok, 5)
      assert limiter_state().in_flight == %{}
    end

    test "a full project does not hold up another project" do
      test_pid = self()

      stub(KataRunnerMock, :cmd, fn argv, cwd, [] ->
        send(test_pid, {:runner_started, self(), argv, cwd})

        if cwd == @cwd do
          receive do
            {:finish, result} -> result
          end
        else
          {:ok, @changed_envelope}
        end
      end)

      blocked = start_callers(@cwd, 4)
      runners = collect_started(4)

      assert :ok = KataAdapter.add_dependency("c1", "d1", %{cwd: @other_cwd})

      Enum.each(runners, &finish/1)
      Enum.each(blocked, &Task.await(&1, 5_000))
    end

    test "the version probe `available?/0` holds a slot too" do
      fake_kata_on_path!()
      stub_blocking_runner()

      probe = Task.async(&KataAdapter.available?/0)
      [runner] = collect_started(1)

      assert limiter_state().in_flight == %{File.cwd!() => 1}

      finish(runner, {:ok, "kata v0.23.0\n"})
      assert Task.await(probe, 5_000) == true
      assert limiter_state().in_flight == %{}
    end

    test "the slot belongs to the limiter process the application supervises (AC-009-1, T025)" do
      stub_blocking_runner()

      supervised = Process.whereis(ConcurrencyLimiter)
      assert is_pid(supervised) and Process.alive?(supervised)

      assert Enum.any?(
               Supervisor.which_children(ForemanServer.Application),
               &match?({ConcurrencyLimiter, ^supervised, :worker, _modules}, &1)
             )

      [caller] = start_callers(@cwd, 1)
      [runner] = collect_started(1)

      assert :sys.get_state(supervised).in_flight == %{@cwd => 1}

      finish(runner)
      assert Task.await(caller, 5_000) == :ok
    end
  end

  describe "AC-009-2: a caller without a slot in time gets a typed, retryable error" do
    test "the fifth caller receives BR_TIMEOUT_QUEUE after the queue timeout, without running kata" do
      put_queue_timeout!(100)
      stub_blocking_runner()

      held = start_callers(@cwd, 4)
      runners = collect_started(4)

      started_at = System.monotonic_time(:millisecond)

      assert {:error,
              %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true, context: context} = error} =
               KataAdapter.add_dependency("e1", "f1", %{cwd: @cwd})

      waited_ms = System.monotonic_time(:millisecond) - started_at

      assert waited_ms >= 80
      assert waited_ms < 10_000

      refute_receive {:runner_started, _pid, _argv, _cwd}, 100
      assert limiter_state().in_flight == %{@cwd => 4}
      assert :queue.is_empty(limiter_state().waiters)

      assert Enum.sort(Map.keys(context)) == Enum.sort(BuildProviderError.context_keys())
      assert context.id == "BR_TIMEOUT_QUEUE"

      assert context.command == %{binary: "kata"}
      assert error.message != ""

      Enum.each(runners, &finish/1)
      Enum.each(held, &Task.await(&1, 5_000))
    end

    test "the timeout reaches every callback that runs kata, not only mutations" do
      put_queue_timeout!(50)
      stub_blocking_runner()

      held = start_callers(@cwd, 4)
      runners = collect_started(4)

      assert {:error, %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true}} =
               KataAdapter.list_ready(%{cwd: @cwd}, [])

      assert {:error, %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true}} =
               KataAdapter.get("g1", %{cwd: @cwd})

      Enum.each(runners, &finish/1)
      Enum.each(held, &Task.await(&1, 5_000))
    end

    test "the slot is returned after a successful call" do
      stub(KataRunnerMock, :cmd, fn _argv, _cwd, [] -> {:ok, @changed_envelope} end)

      for _ <- 1..6, do: assert(:ok = KataAdapter.add_dependency("h1", "i1", %{cwd: @cwd}))

      assert limiter_state().in_flight == %{}
    end

    test "the slot is returned after a runner failure" do
      stub(KataRunnerMock, :cmd, fn _argv, _cwd, [] -> runner_exit(1) end)

      for _ <- 1..6 do
        assert {:error, %ProviderError{code: "BR_ERROR_ENVELOPE"}} =
                 KataAdapter.add_dependency("j1", "k1", %{cwd: @cwd})
      end

      assert limiter_state().in_flight == %{}
    end

    test "the slot is returned when the runner raises, and the raise is not swallowed" do
      stub(KataRunnerMock, :cmd, fn _argv, _cwd, [] -> raise "runner blew up" end)

      for _ <- 1..6 do
        assert_raise RuntimeError, "runner blew up", fn ->
          KataAdapter.add_dependency("l1", "m1", %{cwd: @cwd})
        end
      end

      assert limiter_state().in_flight == %{}
    end

    test "a slot freed by a finished call lets a queued caller through before its timeout" do
      stub_blocking_runner()

      held = start_callers(@cwd, 4)
      runners = collect_started(4)

      waiting = start_callers(@cwd, 1, 7)
      await_waiters(1)

      finish(hd(runners))
      [late_runner] = collect_started(1)
      finish(late_runner)
      Enum.each(tl(runners), &finish/1)

      assert Task.await(hd(waiting), 5_000) == :ok
      Enum.each(held, &Task.await(&1, 5_000))
    end
  end

  describe "AC-009-1, T025: one limiter instance, used by Kata only" do
    test "the ConcurrencyLimiter moduledoc records the single-instance decision" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(ConcurrencyLimiter)

      assert moduledoc =~ "single globally named instance"
      assert moduledoc =~ "KataAdapter"
      assert moduledoc =~ "BeadsAdapter"
    end

    test "no code under lib/ other than the limiter, its telemetry, the application and KataAdapter names it" do
      referencing =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "ConcurrencyLimiter"))
        |> Enum.map(&Path.relative_to(&1, @lib_root))
        |> Enum.sort()

      assert referencing == @limiter_references
    end
  end

  ## Helpers

  # The `kata` runner blocks until the test sends `{:finish, result}` to the process running it.
  defp stub_blocking_runner do
    test_pid = self()

    stub(KataRunnerMock, :cmd, fn argv, cwd, [] ->
      send(test_pid, {:runner_started, self(), argv, cwd})

      receive do
        {:finish, result} -> result
      end
    end)
  end

  defp start_callers(cwd, count, offset \\ 0) do
    for index <- (offset + 1)..(offset + count)//1 do
      Task.async(fn ->
        KataAdapter.add_dependency("a#{index}", "b#{index}", %{cwd: cwd})
      end)
    end
  end

  defp collect_started(count) do
    for _ <- 1..count do
      assert_receive {:runner_started, runner, _argv, _cwd}, 5_000
      runner
    end
  end

  defp finish(runner, result \\ {:ok, @changed_envelope}), do: send(runner, {:finish, result})

  defp limiter_state, do: :sys.get_state(ConcurrencyLimiter)

  defp await_waiters(count) do
    Eventually.await(
      fn -> :queue.len(limiter_state().waiters) == count end,
      message: "#{count} caller(s) never queued behind the full limiter"
    )
  end

  # `ConcurrencyLimiter.init/1` reads this existing key; restarting under the supervisor applies it.
  defp put_queue_timeout!(timeout_ms) do
    config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.put(config, :timeout_ms, timeout_ms)
    )

    restart_limiter!()
  end

  defp restart_limiter! do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ConcurrencyLimiter)
    {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, ConcurrencyLimiter)
    :ok
  end

  defp fake_kata_on_path! do
    bin_dir =
      Path.join(
        System.tmp_dir!(),
        "kata_concurrency_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(bin_dir)
    script = Path.join(bin_dir, "kata")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf!(bin_dir) end)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp runner_exit(exit_code) do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_ERROR_ENVELOPE",
         "Kata CLI exited with a non-zero status.",
         nil,
         false
       ),
       exit_code,
       0
     )}
  end
end
