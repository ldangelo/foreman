defmodule ForemanServer.TelemetryTest.Handler do
  @moduledoc """
  Test helper that attaches a `:telemetry` handler forwarding every
  received event to the calling process.

  Previously this module lived inside `telemetry_test.exs` and was
  therefore only available when running that test. Extracting it
  to a support module makes it visible to other test files (e.g.
  `boot_reconciliation_run_slots_test.exs`).
  """

  @doc """
  Attaches a `:telemetry` handler covering every event name in
  `events` and forwards each one to `pid` via `send/2` using the
  shape `{event, ref, measurements, metadata}`.

  Returns `{handler_id, ref}` where `handler_id` is the
  `:telemetry.attach_many` handler key (a tuple) and `ref` is the
  unique reference the test can pattern-match on in `assert_receive`.
  Both are valid arguments to `:telemetry.detach/1`.
  """
  @spec attach_event_handlers(pid(), [...]) :: {{atom(), reference()}, reference()}
  def attach_event_handlers(pid, events) do
    ref = make_ref()
    handler_id = {:telemetry_test, ref}
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {pid, ref})
    {handler_id, ref}
  end

  @doc false
  def handle_event(event, measurements, metadata, {pid, ref}) do
    send(pid, {event, ref, measurements, metadata})
  end
end
