defmodule ForemanServer.Workflow.RetiredGlobalSlotsBootWarningTest do
  # Mutates application env and the Logger: not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.RunSlotsMigration

  setup do
    previous = Application.get_env(:foreman_server, :max_concurrent_runs)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :max_concurrent_runs),
        else: Application.put_env(:foreman_server, :max_concurrent_runs, previous)
    end)

    :ok
  end

  test "a leftover :max_concurrent_runs value is ignored with one warning and boot continues (AC-008-3)" do
    Application.put_env(:foreman_server, :max_concurrent_runs, 9)

    log =
      capture_log([level: :warning], fn ->
        assert :ok = RunSlotsMigration.warn_retired_config()
      end)

    assert log =~ "[warning]"
    assert log =~ ":max_concurrent_runs"
    assert log =~ "retired"
    assert log =~ "ignored"
    assert length(String.split(log, ":max_concurrent_runs")) - 1 == 1
    # The value itself is left alone: nothing reads it, nothing deletes it.
    assert Application.get_env(:foreman_server, :max_concurrent_runs) == 9
  end

  test "no warning when the retired key is not configured" do
    Application.delete_env(:foreman_server, :max_concurrent_runs)

    log =
      capture_log([level: :warning], fn ->
        assert :ok = RunSlotsMigration.warn_retired_config()
      end)

    assert log == ""
  end

  test "Application.start/2 wires the warning" do
    source = File.read!(Path.expand("../../../lib/foreman_server/application.ex", __DIR__))
    assert source =~ "RunSlotsMigration.warn_retired_config()"
  end
end
