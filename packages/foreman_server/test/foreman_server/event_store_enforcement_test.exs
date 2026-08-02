defmodule ForemanServer.EventStoreEnforcementTest do
  @moduledoc """
  TRD-041 / AC-021-3 architecture invariant — SCOPED to the three NEW
  code paths added by TRD-041:

    1. `ProjectRunLimit` slot reservation (run.start saga)
    2. `ProjectRunLimit` slot release (run.fail/run.complete saga)
    3. `StreamGapDetector` alert dispatch

  All three MUST route through a single gap-checked append path so
  the run-limit cap and stream-gap guard can never be bypassed. The
  pre-existing modules (`attach_bridge`, `inbox`, `overwatch`,
  `scheduler`, etc.) were not touched by TRD-041 and the ground
  truth forbids us from refactoring them in this slice, so this test
  does NOT assert a global "only CommandRouter may call
  EventStore.append" invariant.

  Enforcement strategy:

    * **Static** (compile-time invariant): the slot reservation /
      release functions in `command_router.ex` MUST route through
      the `checked_slot_append/4` helper instead of calling
      `EventStore.append/1` directly. This is the structural fix that
      closes the slot-stream bypass the original test missed.

    * **Behavioral** (runtime invariant): a blocked slot stream
      (`project_run_limit:<project>`) MUST cause `run.start` to
      reject with `{:error, :stream_gap}`, NOT a successful slot
      reservation on a drift-suspect stream. Same applies to
      `run.fail` / `run.complete` releases.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib/foreman_server", __DIR__)

  test "reserve_slot routes through checked_slot_append (no direct EventStore.append)" do
    router = Path.join(@lib_root, "command_router.ex")
    contents = File.read!(router)

    # Extract the reserve_slot function body and assert it does NOT
    # contain a direct EventStore.append( call. The only append call
    # in the saga must be inside `checked_slot_append/4`.
    body = extract_function(contents, "defp reserve_slot(")

    refute body =~ "EventStore.append(",
           "reserve_slot must NOT call EventStore.append/1 directly; it must " <>
             "route through checked_slot_append/4 so the gap-guard fires."

    assert body =~ "checked_slot_append(",
           "reserve_slot must delegate to checked_slot_append/4 so the " <>
             "gap-guard consults the detector before writing to " <>
             "`project_run_limit:<id>`."
  end

  test "release_slot routes through checked_slot_append (no direct EventStore.append)" do
    router = Path.join(@lib_root, "command_router.ex")
    contents = File.read!(router)

    body = extract_function(contents, "defp release_slot(")

    refute body =~ "EventStore.append(",
           "release_slot must NOT call EventStore.append/1 directly; it must " <>
             "route through checked_slot_append/4 so the gap-guard fires."

    assert body =~ "checked_slot_append(",
           "release_slot must delegate to checked_slot_append/4."
  end

  test "checked_slot_append is defined in command_router.ex" do
    router = Path.join(@lib_root, "command_router.ex")
    contents = File.read!(router)

    assert contents =~ "defp checked_slot_append(",
           "command_router.ex must define checked_slot_append/4 — the " <>
             "shared gap-checked append helper for slot operations."

    body = extract_function(contents, "defp checked_slot_append(")

    assert body =~ "check_stream_gap(",
           "checked_slot_append/4 MUST consult check_stream_gap/2 before " <>
             "EventStore.append/1, otherwise slot appends bypass the " <>
             "drift guard."

    assert body =~ "EventStore.append(",
           "checked_slot_append/4 must contain the EventStore.append/1 " <>
             "call it gates (proves the helper is the single append site)."
  end

  test "ProjectRunLimit aggregate is a callback-only aggregate (no direct append)" do
    aggregate = Path.join(@lib_root, "aggregates/project_run_limit.ex")
    assert File.regular?(aggregate), "expected aggregates/project_run_limit.ex to exist"

    contents = File.read!(aggregate)

    refute contents =~ "EventStore.append(",
           "ProjectRunLimit is a callback aggregate: it returns a decision " <>
             "(event spec) for the router/aggregate layer to append; it does " <>
             "NOT append to the event store itself."
  end

  test "StreamGapDetector routes alerts through CommandRouter.handle/1" do
    detector = Path.join(@lib_root, "stream_gap_detector.ex")
    assert File.regular?(detector), "expected stream_gap_detector.ex to exist"

    contents = File.read!(detector)

    assert contents =~ "CommandRouter.handle(",
           "StreamGapDetector must dispatch `stream_gap.detect` through " <>
             "CommandRouter.handle/1 so the alert obeys the gap-guard " <>
             "short-circuit and emits a typed event."

    refute contents =~ "EventStore.append(",
           "StreamGapDetector must NOT call EventStore.append/1 directly; " <>
             "alerts route through CommandRouter.handle/1 only."
  end

  test "stream_gap.detect routes to the dedicated alerts stream (not the affected stream)" do
    router = Path.join(@lib_root, "command_router.ex")
    contents = File.read!(router)

    assert contents =~ ~s|"stream_gap_alerts"|,
           "stream_gap.detect must route the alert to the dedicated " <>
             "`stream_gap_alerts` stream so the detector cannot self-" <>
             "deadlock when the affected stream is blocked."
  end

  test "stream_gap.detect is exempt from check_stream_gap" do
    router = Path.join(@lib_root, "command_router.ex")
    contents = File.read!(router)

    assert contents =~ ~s|check_stream_gap("stream_gap.detect", _stream_id), do: :ok|,
           "check_stream_gap/2 must short-circuit with :ok for the " <>
             "`stream_gap.detect` command type so the detector's own " <>
             "alert is not blocked by the gap it just reported."
  end

  # --- helpers ---

  defp extract_function(contents, head) do
    lines = String.split(contents, "\n")
    start = Enum.find_index(lines, &String.contains?(&1, head))

    if is_nil(start) do
      ""
    else
      # Track `do/end` depth to find the matching close. We don't
      # try to be a full Elixir parser — we only need to bound a
      # defp body whose content doesn't contain nested defmodules.
      {body, _} =
        lines
        |> Enum.drop(start)
        |> Enum.reduce_while({[], 0}, fn line, {acc, depth} ->
          cond do
            depth == 0 and String.contains?(line, " do") ->
              {:cont, {acc ++ [line], 1}}

            depth > 0 and String.trim(line) == "end" and depth == 1 ->
              {:halt, {acc ++ [line], depth}}

            depth > 0 and String.trim(line) == "end" ->
              {:cont, {acc ++ [line], depth - 1}}

            depth > 0 and String.contains?(line, " do") ->
              {:cont, {acc ++ [line], depth + 1}}

            true ->
              {:cont, {acc ++ [line], depth}}
          end
        end)

      Enum.join(body, "\n")
    end
  end
end
