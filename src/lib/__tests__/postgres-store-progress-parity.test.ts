import { describe, expect, it, vi } from "vitest";
import { PostgresStore } from "../postgres-store.js";
import type { PostgresAdapter } from "../db/postgres-adapter.js";
import type { RunProgress } from "../store.js";

describe("PostgresStore progress parity", () => {
  it("round-trips the full worker progress shape through getRunProgress", async () => {
    let storedProgress = "";
    const adapter = {
      getRun: vi.fn(async () => ({
        id: "run-1",
        project_id: "proj-1",
        seed_id: "seed-1",
        agent_type: "worker",
        session_key: null,
        worktree_path: null,
        status: "running",
        started_at: null,
        completed_at: null,
        created_at: "2026-04-25T00:00:00.000Z",
        progress: storedProgress || null,
      })),
      updateRunProgress: vi.fn(async (_projectId: string, _runId: string, progress: Record<string, unknown>) => {
        storedProgress = JSON.stringify(progress);
      }),
    } as unknown as PostgresAdapter;

    const store = new PostgresStore("proj-1", adapter);
    const progress: RunProgress = {
      toolCalls: 17,
      toolBreakdown: { Read: 5, Edit: 3, Bash: 9 },
      filesChanged: ["src/a.ts", "src/b.ts"],
      turns: 12,
      costUsd: 4.2,
      tokensIn: 123,
      tokensOut: 456,
      lastToolCall: "Edit",
      lastActivity: "2026-04-25T00:01:00.000Z",
      currentPhase: "developer",
      costByPhase: { developer: 4.2 },
      agentByPhase: { developer: "claude-sonnet-4-6" },
      qaValidatedTargetBranch: "main",
      qaValidatedTargetRef: "target-ref",
      qaValidatedHeadRef: "head-ref",
      currentTargetRef: "current-ref",
      epicTaskCount: 3,
      epicTasksCompleted: 1,
      epicCurrentTaskId: "seed-1",
      epicCostByTask: { "seed-1": 4.2 },
    };

    await store.updateRunProgress("run-1", progress);

    expect(adapter.updateRunProgress).toHaveBeenCalledWith("proj-1", "run-1", expect.objectContaining({
      toolCalls: 17,
      toolBreakdown: { Read: 5, Edit: 3, Bash: 9 },
      filesChanged: ["src/a.ts", "src/b.ts"],
      turns: 12,
      costUsd: 4.2,
      tokensIn: 123,
      tokensOut: 456,
      lastToolCall: "Edit",
      lastActivity: "2026-04-25T00:01:00.000Z",
      currentPhase: "developer",
      costByPhase: { developer: 4.2 },
      agentByPhase: { developer: "claude-sonnet-4-6" },
      qaValidatedTargetBranch: "main",
      qaValidatedTargetRef: "target-ref",
      qaValidatedHeadRef: "head-ref",
      currentTargetRef: "current-ref",
      epicTaskCount: 3,
      epicTasksCompleted: 1,
      epicCurrentTaskId: "seed-1",
      epicCostByTask: { "seed-1": 4.2 },
      phase: "developer",
    }));

    await expect(store.getRunProgress("run-1")).resolves.toEqual(progress);
  });
});
