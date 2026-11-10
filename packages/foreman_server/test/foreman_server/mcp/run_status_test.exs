defmodule ForemanServer.MCP.RunStatusTest do
  @moduledoc """
  `RunStatus.recovery` (TRD-005): the run projection's `run.recovery`, as the
  `foreman_run_status` tool reports it.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    run_id = "run-status-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, project_id: "p", task_id: "t", workflow_snapshot: %{}}
        }
      ])

    %{run_id: run_id}
  end

  test "a run that never needed recovery reports nil", %{run_id: run_id} do
    assert %{recovery: nil} = status!(run_id)
  end

  test "a resumed run reports outcome and elapsed time and nothing else", %{run_id: run_id} do
    record!(run_id, %{outcome: "resumed", elapsed_since_boot_ms: 640})

    assert %{recovery: recovery} = status!(run_id)
    assert recovery == %{outcome: "resumed", elapsed_since_boot_ms: 640}
    assert {:ok, _json} = Jason.encode(status!(run_id))
  end

  test "an effect outcome carries the effect fields, next to the blocked reason", %{
    run_id: run_id
  } do
    record!(run_id, %{
      outcome: "effect_blocked",
      elapsed_since_boot_ms: 910,
      effect_class: "push",
      effect_key: "effect:push:abc",
      effect_verdict: "unknown"
    })

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunBlocked",
          payload: %{run_id: run_id, project_id: "p", reason: "effect_outcome_ambiguous"}
        }
      ])

    assert %{
             status: "blocked",
             failure_reason: "effect_outcome_ambiguous",
             recovery: %{
               outcome: "effect_blocked",
               elapsed_since_boot_ms: 910,
               effect_class: "push",
               effect_key: "effect:push:abc",
               effect_verdict: "unknown"
             }
           } = status!(run_id)
  end

  defp record!(run_id, fields) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunRecoveryAttempted",
          payload: Map.put(fields, :run_id, run_id)
        }
      ])
  end

  defp status!(run_id) do
    assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: run_id})
    dto
  end
end
