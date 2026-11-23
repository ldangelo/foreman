defmodule ForemanServer.DocsPerProjectQueueTest do
  @moduledoc """
  Documentation contract for per-project dispatch queues (TRD-016-TEST, REQ-015).

  The operator documents must describe per-project run slots only: no document may
  describe a global run-slot queue as current behaviour, and the operator guide states
  that total concurrency is the sum of per-project limits (no machine-wide ceiling).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  # CLAUDE.md is an index; the architecture text it indexes lives in docs/lessons/.
  @documents [
    "docs/user-guide.md",
    "docs/cli-reference.md",
    "README.md",
    "CLAUDE.md",
    "docs/lessons/agent-runtime-conventions.md",
    "docs/lessons/workflow-catalog-and-worktree-contract.md",
    "docs/lessons/durable-execution-and-dashboard.md",
    "docs/lessons/beads-sync-and-lease.md",
    "docs/lessons/run-slots-logs-and-signoz.md",
    "docs/lessons/claude-projects-invariants.md"
  ]
  @retired ["global run slot", "global run-slot capacity", "capped by the global"]

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  test "no global-queue description remains (AC-015-1)" do
    for doc <- @documents, phrase <- @retired do
      text = doc |> read!() |> String.downcase() |> String.replace(~r/\s+/, " ")

      refute String.contains?(text, phrase),
             "#{doc} still contains the retired phrase #{inspect(phrase)}"
    end
  end

  test "the architecture notes describe per-project run slots (AC-015-1)" do
    claude = read!("docs/lessons/run-slots-logs-and-signoz.md")
    assert claude =~ "Per-project run slots"
    assert claude =~ "run_slots:<project_id>"
  end

  test "no machine-wide ceiling is stated (AC-015-2)" do
    guide = "docs/user-guide.md" |> read!() |> String.downcase() |> String.replace(~r/\s+/, " ")
    assert guide =~ "total concurrency is the sum of per-project limits"
  end
end
