import { describe, it, expect, vi } from "vitest";
import { execute, toTrackerPriority, toTrackerType } from "../sling-executor.js";
import type {
  SlingPlan,
  SlingOptions,
  ParallelResult,
  Priority,
} from "../types.js";
import type { TaskRow } from "../../lib/task-store.js";

function createMockNativeTaskStore() {
  let counter = 0;
  const byExternalId = new Map<string, TaskRow>();

  const create = vi.fn((opts: {
    title: string;
    description?: string | null;
    type?: string;
    priority?: number;
    externalId?: string | null;
  }) => {
    const row: TaskRow = {
      id: `task-${++counter}`,
      title: opts.title,
      description: opts.description ?? null,
      type: opts.type ?? "task",
      priority: opts.priority ?? 2,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: opts.externalId ?? null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      approved_at: null,
      closed_at: null,
    };
    if (row.external_id) {
      byExternalId.set(row.external_id, row);
    }
    return row;
  });

  const update = vi.fn((id: string, opts: { title?: string; description?: string | null; priority?: number }) => {
    const existing = [...byExternalId.values()].find((row) => row.id === id);
    if (!existing) {
      throw new Error(`Missing task ${id}`);
    }
    const updated: TaskRow = {
      ...existing,
      title: opts.title ?? existing.title,
      description: opts.description ?? existing.description,
      priority: opts.priority ?? existing.priority,
      updated_at: "2026-01-02T00:00:00Z",
    };
    if (updated.external_id) {
      byExternalId.set(updated.external_id, updated);
    }
    return updated;
  });

  return {
    create,
    update,
    close: vi.fn(),
    addDependency: vi.fn(),
    getByExternalId: vi.fn((externalId: string) => byExternalId.get(externalId) ?? null),
  };
}

function makeTestPlan(): SlingPlan {
  return {
    epic: {
      title: "TRD: Test Epic",
      description: "Test description",
      documentId: "TRD-TEST",
      qualityNotes: "Quality notes here",
    },
    sprints: [
      {
        number: 1,
        title: "Sprint 1: Foundation",
        goal: "Foundation",
        priority: "critical" as Priority,
        stories: [
          {
            title: "Story 1.1: First Story",
            frNumber: "FR-1",
            acceptanceCriteria: "- AC-1.1: Test passes",
            tasks: [
              {
                trdId: "TP-T001",
                title: "Implement feature A",
                estimateHours: 3,
                dependencies: [],
                files: ["src/a.ts"],
                status: "open",
              },
              {
                trdId: "TP-T002",
                title: "Write tests for feature A",
                estimateHours: 2,
                dependencies: ["TP-T001"],
                files: ["src/__tests__/a.test.ts"],
                status: "open",
              },
            ],
          },
        ],
        summary: {
          focus: "Foundation",
          estimatedHours: 5,
          deliverables: "Feature A",
        },
      },
      {
        number: 2,
        title: "Sprint 2: Advanced",
        goal: "Advanced features",
        priority: "high" as Priority,
        stories: [
          {
            title: "Story 2.1: Second Story",
            tasks: [
              {
                trdId: "TP-T003",
                title: "Implement feature B",
                estimateHours: 4,
                dependencies: ["TP-T001"],
                files: ["src/b.ts"],
                status: "completed",
                riskLevel: "high",
              },
            ],
          },
        ],
      },
    ],
    acceptanceCriteria: new Map([["FR-1", "- AC-1.1: Test passes"]]),
    riskMap: new Map([["TP-T003", "high"]]),
  };
}

const DEFAULT_OPTIONS: SlingOptions = {
  dryRun: false,
  auto: false,
  json: false,
  sdOnly: false,
  brOnly: false,
  skipCompleted: false,
  closeCompleted: false,
  noParallel: false,
  force: false,
  noRisks: false,
  noQuality: false,
};

const EMPTY_PARALLEL: ParallelResult = { groups: [], warnings: [] };

describe("toTrackerPriority", () => {
  it("maps priorities correctly", () => {
    expect(toTrackerPriority("critical")).toBe("P0");
    expect(toTrackerPriority("high")).toBe("P1");
    expect(toTrackerPriority("medium")).toBe("P2");
    expect(toTrackerPriority("low")).toBe("P3");
  });
});

describe("toTrackerType", () => {
  it("maps types correctly", () => {
    expect(toTrackerType("epic")).toBe("epic");
    expect(toTrackerType("sprint")).toBe("feature");
    expect(toTrackerType("story")).toBe("feature");
    expect(toTrackerType("task")).toBe("task");
    expect(toTrackerType("spike")).toBe("chore");
    expect(toTrackerType("test")).toBe("task");
  });
});

describe("execute", () => {
  it("creates hierarchy in the native store", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    expect(result.native.created).toBe(8);
    expect(result.native.epicId).toBeDefined();
    expect(taskStore.create).toHaveBeenCalledTimes(8);
  });

  it("wires parent-child and blocking dependencies", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const calls = taskStore.addDependency.mock.calls.map(([from, to, type]) => ({ from, to, type }));
    expect(calls.some((call) => call.type === "parent-child")).toBe(true);
    expect(calls.some((call) => call.type === "blocks")).toBe(true);
  });

  it("stores TRD metadata in task descriptions", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const taskCall = taskStore.create.mock.calls.find(
      ([opts]) => opts.title === "Implement feature A",
    );
    expect(taskCall).toBeDefined();
    expect(taskCall![0].description).toContain("trd:TP-T001");
  });

  it("applies risk metadata when enabled", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const riskTask = taskStore.create.mock.calls.find(
      ([opts]) => opts.title === "Implement feature B",
    );
    expect(riskTask).toBeDefined();
    expect(riskTask![0].description).toContain("risk:high");
  });

  it("skips risk metadata when --no-risks", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, noRisks: true };

    await execute(plan, EMPTY_PARALLEL, options, taskStore as never);

    const riskTask = taskStore.create.mock.calls.find(
      ([opts]) => opts.title === "Implement feature B",
    );
    expect(riskTask![0].description).not.toContain("risk:high");
  });

  it("skips completed tasks with --skip-completed", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, skipCompleted: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, taskStore as never);

    expect(result.native.skipped).toBe(1);
    expect(result.native.created).toBe(7);
  });

  it("creates then closes completed tasks with --close-completed", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, closeCompleted: true };

    await execute(plan, EMPTY_PARALLEL, options, taskStore as never);

    expect(taskStore.close).toHaveBeenCalledTimes(1);
  });

  it("records parallel metadata on sprint descriptions", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const parallel: ParallelResult = {
      groups: [{ label: "A", sprintIndices: [0, 1] }],
      warnings: [],
    };

    await execute(plan, parallel, DEFAULT_OPTIONS, taskStore as never);

    const sprintCalls = taskStore.create.mock.calls.filter(
      ([opts]) => opts.title.startsWith("Sprint "),
    );
    expect(sprintCalls).toHaveLength(2);
    for (const [opts] of sprintCalls) {
      expect(opts.description).toContain("parallel:A");
    }
  });

  it("adds quality notes to epic description when enabled", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const epicCall = taskStore.create.mock.calls[0];
    expect(epicCall![0].description).toContain("Quality notes here");
  });

  it("skips quality notes with --no-quality", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, noQuality: true };

    await execute(plan, EMPTY_PARALLEL, options, taskStore as never);

    const epicCall = taskStore.create.mock.calls[0];
    expect(epicCall![0].description).not.toContain("Quality notes here");
  });

  it("infers test kind metadata from title", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const testCall = taskStore.create.mock.calls.find(
      ([opts]) => opts.title === "Write tests for feature A",
    );
    expect(testCall![0].description).toContain("kind:test");
  });

  it("includes sprint summary in description", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    const sprintCall = taskStore.create.mock.calls.find(
      ([opts]) => opts.title === "Sprint 1: Foundation",
    );
    expect(sprintCall![0].description).toContain("Focus: Foundation");
    expect(sprintCall![0].description).toContain("Estimated Hours: 5");
  });

  it("calls onProgress callback with native tracker", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const onProgress = vi.fn();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never, onProgress);

    expect(onProgress).toHaveBeenCalled();
    const lastCall = onProgress.mock.calls[onProgress.mock.calls.length - 1];
    expect(lastCall[2]).toBe("native");
  });

  it("handles task creation failure gracefully", async () => {
    const taskStore = createMockNativeTaskStore();
    let callCount = 0;
    taskStore.create.mockImplementation((opts) => {
      callCount++;
      if (callCount === 5) throw new Error("Connection timeout");
      return {
        id: `task-${callCount}`,
        title: opts.title,
        description: opts.description ?? null,
        type: opts.type ?? "task",
        priority: opts.priority ?? 2,
        status: "backlog",
        run_id: null,
        branch: null,
        external_id: opts.externalId ?? null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        approved_at: null,
        closed_at: null,
      } satisfies TaskRow;
    });
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);

    expect(result.native.failed).toBe(1);
    expect(result.native.errors.length).toBeGreaterThan(0);
    expect(result.native.errors[0]).toContain("SLING-006");
  });

  it("updates existing tasks when --force is enabled", async () => {
    const taskStore = createMockNativeTaskStore();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, taskStore as never);
    taskStore.create.mockClear();

    const result = await execute(plan, EMPTY_PARALLEL, { ...DEFAULT_OPTIONS, force: true }, taskStore as never);

    expect(result.native.created).toBe(8);
    expect(taskStore.update).toHaveBeenCalled();
    expect(taskStore.create).not.toHaveBeenCalled();
  });
});
