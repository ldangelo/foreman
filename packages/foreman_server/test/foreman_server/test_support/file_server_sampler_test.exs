defmodule ForemanServer.TestSupport.FileServerSamplerTest do
  # Not async: `capture_io(:stderr, ...)` swaps the global stderr device, so a concurrent test
  # writing to stderr would show up in (or be swallowed by) these assertions.
  #
  # foreman-83cf1: FileServerSampler is the only evidence a stalled `:file_server_2` will ever
  # leave, and it is silent while healthy, so nothing else notices if it stops working. These
  # tests use a stand-in process under a throwaway name. They NEVER suspend or block the real
  # `:file_server_2`, which every concurrent async test depends on.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ForemanServer.TestSupport.Eventually
  alias ForemanServer.TestSupport.FileServerSampler

  @prefix "foreman-83cf1:"
  @victim_files [
    "test/foreman_server/library/ingest_test.exs",
    "test/foreman_server/architecture/reopen_call_site_test.exs"
  ]

  # ExUnit's default per-test timeout, which both victim tests rely on (neither overrides it).
  @exunit_default_timeout_ms 60_000

  defmodule Parked do
    @moduledoc false
    # Blocks in a selective receive for a message nobody sends: status `:waiting`, a recognisable
    # stacktrace, and every other message piles up in the mailbox.
    def park do
      receive do
        :never_sent -> :ok
      end
    end
  end

  setup do
    name = :"file_server_sampler_test_target_#{System.unique_integer([:positive])}"
    {:ok, name: name}
  end

  # A stand-in for `:file_server_2` that is healthy: an idle process, empty mailbox.
  defp start_healthy_target!(name) do
    pid = start_supervised!(%{id: name, start: {Agent, :start_link, [fn -> 0 end, [name: name]]}})
    pid
  end

  # A stand-in that is stuck: parked in a receive, with `queued` unmatched messages behind it.
  defp start_stuck_target!(name, queued) do
    pid = spawn(&Parked.park/0)
    on_exit(fn -> Process.exit(pid, :kill) end)
    Process.register(pid, name)
    for n <- 1..queued, do: send(pid, {:queued, n})
    pid
  end

  defp state(sampler), do: :sys.get_state(sampler)

  # Blocks until the sampler's newest snapshot is at least `ms` after it started.
  defp await_elapsed(sampler, ms) do
    Eventually.await(fn -> hd(state(sampler).snapshots).at_ms >= ms end,
      timeout: 10_000,
      message: "sampler did not reach #{ms}ms"
    )
  end

  describe "healthy target" do
    test "prints nothing to stderr even after several sampling intervals", %{name: name} do
      start_healthy_target!(name)

      stderr =
        capture_io(:stderr, fn ->
          # Production threshold (the default), short interval: the sampler really samples.
          sampler =
            start_supervised!({FileServerSampler, target: name, interval_ms: 20, owner: self()})

          Eventually.await(fn -> length(state(sampler).snapshots) >= 3 end,
            message: "sampler never took 3 snapshots"
          )

          stop_supervised!(FileServerSampler)
        end)

      assert stderr == ""
    end

    test "a test that ends before the threshold never dumps", %{name: name} do
      start_healthy_target!(name)

      stderr =
        capture_io(:stderr, fn ->
          sampler =
            start_supervised!(
              {FileServerSampler,
               target: name, interval_ms: 20, dump_after_ms: 120_000, owner: self()}
            )

          Eventually.await(fn -> length(state(sampler).snapshots) >= 3 end)
          stop_supervised!(FileServerSampler)
        end)

      assert stderr == ""
    end
  end

  describe "stalled target" do
    test "dumps queue length, status, stacktraces and the stuck test once past the threshold",
         %{name: name} do
      target = start_stuck_target!(name, 3)

      stderr =
        capture_io(:stderr, fn ->
          sampler =
            start_supervised!(
              {FileServerSampler,
               target: name, interval_ms: 20, dump_after_ms: 300, keep: 3, owner: self()}
            )

          # Wait well past the threshold and then for many more ticks: a second dump would land
          # in this window. Driven by the sampler's own clock, so a loaded host only waits longer.
          await_elapsed(sampler, 300 + 400)

          stop_supervised!(FileServerSampler)
        end)

      lines = String.split(stderr, "\n", trim: true)

      # Every emitted line carries the greppable prefix.
      assert lines != []
      assert Enum.all?(lines, &String.starts_with?(&1, @prefix)), stderr

      # Dumped exactly once.
      assert length(Regex.scan(~r/test still running after \d+ms/, stderr)) == 1

      # The last `keep` snapshots of the target: queue length, status and a stacktrace.
      snapshot_lines = Enum.filter(lines, &(&1 =~ " message_queue_len="))
      assert length(snapshot_lines) == 3, stderr
      assert Enum.all?(snapshot_lines, &(&1 =~ "message_queue_len=3 status=waiting stacktrace:"))
      assert stderr =~ inspect(name)

      assert stderr =~ "ForemanServer.TestSupport.FileServerSamplerTest.Parked.park/0",
             "target stacktrace missing from dump:\n" <> stderr

      assert stderr =~ "run_queue="
      assert stderr =~ "schedulers_online="

      # The stuck test's own stacktrace is included.
      assert stderr =~ "test process #{inspect(self())} status="
      assert Process.alive?(target)
    end

    test "dumps a not-registered marker rather than crashing when the target is absent", %{
      name: name
    } do
      stderr =
        capture_io(:stderr, fn ->
          sampler =
            start_supervised!(
              {FileServerSampler, target: name, interval_ms: 20, dump_after_ms: 100}
            )

          # Past the threshold (the dump, if any, ran in the same callback as the newest sample).
          await_elapsed(sampler, 100 + 200)
          stop_supervised!(FileServerSampler)
        end)

      assert stderr =~ "#{@prefix} t="
      assert stderr =~ "#{inspect(name)} not registered"
    end
  end

  describe "threshold vs ExUnit timeout" do
    test "the default dump threshold fires before, and shortly before, the 60 s ExUnit timeout" do
      default = FileServerSampler.default_dump_after_ms()

      assert default < @exunit_default_timeout_ms
      # Late enough that a healthy slow test is not dumped, early enough that the dump still
      # happens while the stuck state exists (the timeout kill destroys it).
      assert default >= @exunit_default_timeout_ms - 30_000
    end

    test "a sampler started without :dump_after_ms (as the victim tests do) uses that default",
         %{name: name} do
      start_healthy_target!(name)
      sampler = start_supervised!({FileServerSampler, target: name, interval_ms: 20})

      assert state(sampler).dump_after_ms == FileServerSampler.default_dump_after_ms()
    end

    test "the suite's effective ExUnit timeout is not below the default threshold" do
      assert ExUnit.configuration()[:timeout] > FileServerSampler.default_dump_after_ms()
    end

    test "nothing raises or lowers the timeout of the two victim tests or of the suite" do
      for path <- @victim_files do
        source = File.read!(path)

        assert source =~ "FileServerSampler.start()",
               "#{path} no longer starts the sampler with its default threshold"

        refute source =~ ~r/@(module)?tag\b[^\n]*\btimeout\b/,
               "#{path} sets a tag timeout; the sampler threshold assumes the #{@exunit_default_timeout_ms} ms default"

        refute source =~ ~r/ExUnit\.configure/, "#{path} reconfigures ExUnit"
      end

      helper = File.read!("test/test_helper.exs")

      refute helper =~ ~r/ExUnit\.(configure|start)\([^)]*\btimeout:/s,
             "test_helper.exs sets an ExUnit timeout; re-derive FileServerSampler's threshold"
    end
  end
end
