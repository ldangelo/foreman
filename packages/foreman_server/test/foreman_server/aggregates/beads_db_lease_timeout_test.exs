defmodule ForemanServer.Aggregates.BeadsDbLeaseTimeoutTest do
  @moduledoc """
  A lease actor that does not answer costs its caller that one call, never the caller.

  `BeadsDbLease.with_lease/4` dispatches `lease.acquire` and `lease.release` through the
  command router. When the lease actor was slow, the router's call timed out with an exit that
  escaped `with_lease/4`: the `BeadsWatcher` died twice, and a `RunExecutor` died at run
  completion (see `ForemanServer.CommandTimeout`). Now:

    * an acquire that is not answered is `{:error, %CommandTimeout{}}`, after the call has asked
      for its queue entry and its hold back;
    * a release that is not answered is the `ReleaseError` the module documents for exactly that,
      carrying the typed timeout as its reason.

  The actor is held with `:sys.suspend/1`. The commands sent to it wait in its mailbox in order,
  so a command that timed out is still applied when the actor is resumed, and the cleanup queued
  behind it undoes it: nothing is left holding the lease.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregates.BeadsDbLease.ReleaseError
  alias ForemanServer.{Aggregator, CommandTimeout}
  alias ForemanServer.TaskProviders.BeadsWatcher

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "lease-timeout-#{System.unique_integer([:positive])}.db")
    stream = BeadsDbLease.stream_id(db_path)
    {:ok, actor} = Aggregator.start_aggregate(ForemanServer.Aggregates.BeadsDbLease, stream)
    on_exit(fn -> resume_quietly(actor) end)

    {:ok, db_path: db_path, stream: stream, actor: actor}
  end

  defp resume_quietly(actor) do
    :sys.resume(actor)
  catch
    :exit, _ -> :ok
  end

  # Resumes `actor` once `count` commands wait in its mailbox: the first has timed out, and the
  # cleanup of the call is behind it.
  defp resume_when_queued(actor, count) do
    Task.async(fn ->
      await_queued(actor, count)
      :sys.resume(actor)
    end)
  end

  defp await_queued(actor, count, attempts \\ 1_000) do
    {:message_queue_len, queued} = Process.info(actor, :message_queue_len)

    cond do
      queued >= count ->
        :ok

      attempts == 0 ->
        flunk("the actor never had #{count} commands waiting (#{queued})")

      true ->
        Process.sleep(10)
        await_queued(actor, count, attempts - 1)
    end
  end

  describe "with_lease/4 and an actor that does not answer the acquire" do
    test "is a typed error, and the hold the late acquire takes is given back",
         %{db_path: db_path, stream: stream, actor: actor} do
      :ok = :sys.suspend(actor)
      resumer = resume_when_queued(actor, 2)

      assert {:error,
              %CommandTimeout{
                aggregate_id: ^stream,
                command_type: "lease.acquire",
                timeout_ms: 5_000
              }} =
               BeadsDbLease.with_lease(db_path, "run-timeout", "task-timeout", fn ->
                 flunk("the callback ran without the lease")
               end)

      Task.await(resumer)

      # The acquire that timed out was applied the moment the actor came back (it was first in
      # its mailbox), and the removal and release queued behind it ran after it.
      assert %BeadsDbLease.State{holder: nil, waiters: []} = Actor.get_state(actor)
    end
  end

  describe "with_lease/4 and an actor that does not answer the release" do
    test "is the ReleaseError the module documents for it, carrying the typed timeout",
         %{db_path: db_path, stream: stream, actor: actor} do
      error =
        assert_raise ReleaseError, fn ->
          BeadsDbLease.with_lease(db_path, "run-release", "task-release", fn ->
            # The call holds the lease. From here the actor answers nothing, so the release
            # that follows the callback is the command that times out.
            :ok = :sys.suspend(actor)
            {:ok, :closed}
          end)
        end

      assert %ReleaseError{
               stream_id: ^stream,
               run_id: "run-release",
               reason: %CommandTimeout{command_type: "lease.release", timeout_ms: 5_000}
             } = error

      # The release is still in the actor's mailbox: it gives the lease back when it is resumed.
      :ok = :sys.resume(actor)
      assert %BeadsDbLease.State{holder: nil} = Actor.get_state(actor)
    end
  end

  describe "the BeadsWatcher and an actor that does not answer" do
    test "skips the pass it could not take the lease for, and lives to take the next",
         %{tmp_dir: tmp_dir, db_path: db_path, actor: actor} do
      jsonl_path = Path.join(tmp_dir, "issues.jsonl")
      File.write!(jsonl_path, "")

      state = %BeadsWatcher{
        project_id: "proj-lease-timeout",
        jsonl_path: jsonl_path,
        database_path: db_path,
        poll_ms: 1_000
      }

      :ok = :sys.suspend(actor)
      resumer = resume_when_queued(actor, 2)

      log =
        capture_log([level: :warning], fn ->
          # This call used to exit with the router's timeout, which killed the watcher.
          assert ^state = BeadsWatcher.boot_replay(state)
        end)

      Task.await(resumer)

      assert log =~ "lease_acquire failed"
      assert log =~ "lease.acquire"
      assert log =~ "timeout_ms: 5000"
    end
  end
end
