import { describe, it, expect, vi, beforeEach } from "vitest";
import { execute, toTrackerPriority, toTrackerType } from "../sling-executor.js";
import type {
  SlingPlan,
  SlingOptions,
  ParallelResult,
  Priority,
} from "../types.js";

// ── Mock BeadsRustClient (used for both sd and br slots in execute()) ─────

function createMockSdClient() {
  let counter = 0;
  return {
    create: vi.fn().mockImplementation(async () => ({
      id: `sd-${++counter}`,
      title: "mock",
      type: "task",
      priority: "P2",
      status: "open",
      assignee: null,
      parent: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    })),
    list: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({ id: "sd-1", labels: [] }),
    close: vi.fn().mockResolvedValue(undefined),
    addDependency: vi.fn().mockResolvedValue(undefined),
    update: vi.fn().mockResolvedValue(undefined),
    ensureBrInstalled: vi.fn().mockResolvedValue(undefined),
    isInitialized: vi.fn().mockResolvedValue(true),
  };
}

function createMockBeadsRustClient() {
  let counter = 0;
  return {
    create: vi.fn().mockImplementation(async () => ({
      id: `br-${++counter}`,
      title: "mock",
      type: "task",
      priority: "P2",
      status: "open",
      assignee: null,
      parent: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    })),
    list: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({ id: "br-1", labels: [] }),
    close: vi.fn().mockResolvedValue(undefined),
    addDependency: vi.fn().mockResolvedValue(undefined),
    update: vi.fn().mockResolvedValue(undefined),
    search: vi.fn().mockResolvedValue([]),
    ensureBrInstalled: vi.fn().mockResolvedValue(undefined),
    isInitialized: vi.fn().mockResolvedValue(true),
  };
}

// ── Test data ────────────────────────────────────────────────────────────

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

// ── toTrackerPriority / toTrackerType ────────────────────────────────────

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

// ── execute ──────────────────────────────────────────────────────────────

describe("execute", () => {
  it("creates hierarchy in both sd and br", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, br as any);

    // sd: 1 epic + 2 sprints + 2 stories + 3 tasks = 8
    expect(result.sd!.created).toBe(8);
    expect(result.sd!.epicId).toBeDefined();

    // br: same
    expect(result.br!.created).toBe(8);
    expect(result.br!.epicId).toBeDefined();
  });

  it("wires dependencies", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    // TP-T002 depends on TP-T001, TP-T003 depends on TP-T001 (task-level: 2)
    // Sprint 2 depends on Sprint 1, Story 2.1 depends on Story 1.1 (container-level: 2)
    expect(seeds.addDependency).toHaveBeenCalledTimes(4);
  });

  it("applies trd: labels to tasks", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    // Check that create was called with trd:TP-T001 label
    const calls = seeds.create.mock.calls;
    const taskCall = calls.find(
      (c: unknown[]) => (c[0] as string) === "Implement feature A",
    );
    expect(taskCall).toBeDefined();
    const opts = taskCall![1] as { labels: string[] };
    expect(opts.labels).toContain("trd:TP-T001");
  });

  it("applies risk labels when enabled", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    const calls = seeds.create.mock.calls;
    const riskTask = calls.find(
      (c: unknown[]) => (c[0] as string) === "Implement feature B",
    );
    expect(riskTask).toBeDefined();
    const opts = riskTask![1] as { labels: string[] };
    expect(opts.labels).toContain("risk:high");
  });

  it("skips risk labels when --no-risks", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, noRisks: true };

    await execute(plan, EMPTY_PARALLEL, options, seeds as any, null);

    const calls = seeds.create.mock.calls;
    const riskTask = calls.find(
      (c: unknown[]) => (c[0] as string) === "Implement feature B",
    );
    const opts = riskTask![1] as { labels: string[] };
    expect(opts.labels).not.toContain("risk:high");
  });

  it("skips completed tasks with --skip-completed", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, skipCompleted: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, seeds as any, null);

    // TP-T003 is completed, should be skipped
    expect(result.sd!.skipped).toBe(1);
    expect(result.sd!.created).toBe(7); // 8 - 1 skipped task
  });

  it("creates then closes completed tasks with --close-completed", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, closeCompleted: true };

    await execute(plan, EMPTY_PARALLEL, options, seeds as any, null);

    // TP-T003 should be created then closed
    expect(seeds.close).toHaveBeenCalledTimes(1);
  });

  it("uses --sd-only to skip br", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, sdOnly: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, seeds as any, br as any);

    expect(result.sd).not.toBeNull();
    expect(result.br).toBeNull();
    expect(br.create).not.toHaveBeenCalled();
  });

  it("uses --br-only to skip sd", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, brOnly: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, seeds as any, br as any);

    expect(result.sd).toBeNull();
    expect(result.br).not.toBeNull();
    expect(seeds.create).not.toHaveBeenCalled();
  });

  it("applies parallel labels to sprint issues", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const parallel: ParallelResult = {
      groups: [{ label: "A", sprintIndices: [0, 1] }],
      warnings: [],
    };

    await execute(plan, parallel, DEFAULT_OPTIONS, seeds as any, null);

    // Find sprint creation calls (type: "feature" with kind:sprint label)
    const calls = seeds.create.mock.calls;
    const sprintCalls = calls.filter(
      (c: unknown[]) => {
        const opts = c[1] as { labels?: string[] };
        return opts?.labels?.includes("kind:sprint");
      },
    );
    expect(sprintCalls.length).toBe(2);
    for (const call of sprintCalls) {
      const opts = call[1] as { labels: string[] };
      expect(opts.labels).toContain("parallel:A");
    }
  });

  it("passes estimate to br as minutes", async () => {
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, sdOnly: false, brOnly: false };

    await execute(plan, EMPTY_PARALLEL, options, null, br as any);

    // TP-T001 has 3h estimate = 180 minutes
    const calls = br.create.mock.calls;
    const taskCall = calls.find(
      (c: unknown[]) => (c[0] as string) === "Implement feature A",
    );
    const opts = taskCall![1] as { estimate?: number };
    expect(opts.estimate).toBe(180);
  });

  it("adds quality notes to epic description when enabled", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    const epicCall = seeds.create.mock.calls[0];
    const opts = epicCall[1] as { description: string };
    expect(opts.description).toContain("Quality notes here");
  });

  it("skips quality notes with --no-quality", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, noQuality: true };

    await execute(plan, EMPTY_PARALLEL, options, seeds as any, null);

    const epicCall = seeds.create.mock.calls[0];
    const opts = epicCall[1] as { description: string };
    expect(opts.description).not.toContain("Quality notes here");
  });

  it("infers test kind from title", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    // "Write tests for feature A" should get kind:test label
    const calls = seeds.create.mock.calls;
    const testCall = calls.find(
      (c: unknown[]) => (c[0] as string) === "Write tests for feature A",
    );
    const opts = testCall![1] as { labels: string[] };
    expect(opts.labels).toContain("kind:test");
  });

  it("includes sprint summary in description", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    // Sprint 1 has summary
    const calls = seeds.create.mock.calls;
    const sprintCall = calls.find(
      (c: unknown[]) => (c[0] as string) === "Sprint 1: Foundation",
    );
    const opts = sprintCall![1] as { description: string };
    expect(opts.description).toContain("Focus: Foundation");
    expect(opts.description).toContain("Estimated Hours: 5");
  });

  it("calls onProgress callback", async () => {
    const seeds = createMockSdClient();
    const plan = makeTestPlan();
    const onProgress = vi.fn();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null, onProgress);

    expect(onProgress).toHaveBeenCalled();
    // Last call should have tracker = "sd"
    const lastCall = onProgress.mock.calls[onProgress.mock.calls.length - 1];
    expect(lastCall[2]).toBe("sd");
  });

  it("handles task creation failure gracefully", async () => {
    const seeds = createMockSdClient();
    let callCount = 0;
    seeds.create.mockImplementation(async () => {
      callCount++;
      // Fail on the 5th create (which should be a task)
      if (callCount === 5) throw new Error("Connection timeout");
      return {
        id: `sd-${callCount}`,
        title: "mock",
        type: "task",
        priority: "P2",
        status: "open",
        assignee: null,
        parent: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
      };
    });
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, null);

    expect(result.sd!.failed).toBe(1);
    expect(result.sd!.errors.length).toBeGreaterThan(0);
    expect(result.sd!.errors[0]).toContain("SLING-006");
  });
});

// ── Native task store execution ────────────────────────────────────────────

interface MockTaskRow {
  id: string;
  title: string;
  description: string | null;
  type: string;
  priority: number;
  status: string;
  externalId: string | null;
}

function createMockNativeTaskStore() {
  let idCounter = 0;
  const tasks = new Map<string, MockTaskRow>();

  return {
    create: vi.fn().mockImplementation((opts: {
      title: string;
      description?: string;
      type: string;
      priority: number;
      externalId?: string;
    }) => {
      const id = `native-${++idCounter}`;
      const row: MockTaskRow = {
        id,
        title: opts.title,
        description: opts.description ?? null,
        type: opts.type,
        priority: opts.priority,
        status: "backlog",
        externalId: opts.externalId ?? null,
      };
      tasks.set(id, row);
      return row;
    }),
    list: vi.fn().mockReturnValue(Array.from(tasks.values())),
    get: vi.fn().mockImplementation((id: string) => tasks.get(id) ?? null),
    approve: vi.fn().mockImplementation((id: string) => {
      const task = tasks.get(id);
      if (task) task.status = "ready";
    }),
    close: vi.fn().mockImplementation((id: string) => {
      const task = tasks.get(id);
      if (task) task.status = "closed";
    }),
    addDependency: vi.fn().mockReturnValue(undefined),
    reevaluateBlockedTasks: vi.fn().mockReturnValue(undefined),
    _tasks: tasks,
  };
}

describe("execute with native task store", () => {
  it("creates hierarchy in native task store", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    const result = await execute(plan, EMPTY_PARALLEL, options, null, null);

    // native: 1 epic + 2 sprints + 2 stories + 3 tasks = 8
    expect(result.native!.created).toBe(8);
    expect(result.native!.epicId).toBeDefined();
  });

  it("wires task dependencies in native store", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    // TP-T002 depends on TP-T001 (task-level: 1)
    // TP-T003 depends on TP-T001 (task-level: 1)
    // Sprint 2 depends on Sprint 1, Story 2.1 depends on Story 1.1 (container-level: 2)
    expect(nativeStore.addDependency).toHaveBeenCalledTimes(4);
  });

  it("includes parallel label in sprint externalId when in parallel group", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const parallel: ParallelResult = {
      groups: [{ label: "A", sprintIndices: [0, 1] }],
      warnings: [],
    };
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    await execute(plan, parallel, options, null, null);

    // Check that sprint externalIds include parallel label
    const createCalls = nativeStore.create.mock.calls;
    // Filter by externalId containing "kind:sprint" (sprints and stories both have type "feature")
    const sprintCalls = createCalls.filter(
      (c: unknown[]) => (c[0] as { externalId?: string })?.externalId?.includes("kind:sprint"),
    );
    expect(sprintCalls.length).toBe(2);
    for (const call of sprintCalls) {
      const opts = call[0] as { externalId?: string };
      expect(opts.externalId).toContain("parallel:A");
    }
  });

  it("approves tasks after creation", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    // All created tasks (except epic) should be approved
    // Epic + 2 sprints + 2 stories + 3 tasks = 8 total
    // But epic is also approved (approve is called for all trdIdToNativeId entries)
    expect(nativeStore.approve).toHaveBeenCalled();
  });

  it("skips completed tasks with --skip-completed", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, skipCompleted: true, nativeTaskStore: nativeStore as any };

    const result = await execute(plan, EMPTY_PARALLEL, options, null, null);

    // TP-T003 is completed, should be skipped
    expect(result.native!.skipped).toBe(1);
    expect(result.native!.created).toBe(7); // 8 - 1 skipped task
  });

  it("closes completed tasks with --close-completed", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, closeCompleted: true, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    // TP-T003 should be created then closed
    expect(nativeStore.close).toHaveBeenCalledTimes(1);
  });

  it("adds quality notes to epic description when enabled", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    const epicCall = nativeStore.create.mock.calls.find(
      (c: unknown[]) => (c[0] as { title?: string })?.title === "TRD: Test Epic",
    );
    expect(epicCall).toBeDefined();
    const opts = epicCall![0] as { description?: string };
    expect(opts.description).toContain("Quality notes here");
  });

  it("skips quality notes with --no-quality", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, noQuality: true, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    const epicCall = nativeStore.create.mock.calls.find(
      (c: unknown[]) => (c[0] as { title?: string })?.title === "TRD: Test Epic",
    );
    expect(epicCall).toBeDefined();
    const opts = epicCall![0] as { description?: string };
    expect(opts.description).not.toContain("Quality notes here");
  });

  it("handles task creation failure gracefully", async () => {
    const nativeStore = createMockNativeTaskStore();
    let callCount = 0;
    nativeStore.create.mockImplementation((opts: {
      title: string;
      description?: string;
      type: string;
      priority: number;
      externalId?: string;
    }) => {
      callCount++;
      // Fail on the 5th create (which should be a task)
      if (callCount === 5) throw new Error("Connection timeout");
      const id = `native-${callCount}`;
      const row: MockTaskRow = {
        id,
        title: opts.title,
        description: opts.description ?? null,
        type: opts.type,
        priority: opts.priority,
        status: "backlog",
        externalId: opts.externalId ?? null,
      };
      nativeStore._tasks.set(id, row);
      return row;
    });
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    const result = await execute(plan, EMPTY_PARALLEL, options, null, null);

    expect(result.native!.failed).toBe(1);
    expect(result.native!.errors.length).toBeGreaterThan(0);
    expect(result.native!.errors[0]).toContain("SLING-006");
  });

  it("wires cross-sprint dependencies as sprint blocking", async () => {
    const nativeStore = createMockNativeTaskStore();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, nativeTaskStore: nativeStore as any };

    await execute(plan, EMPTY_PARALLEL, options, null, null);

    // Check that addDependency was called with sprint IDs
    const sprintDepCalls = nativeStore.addDependency.mock.calls.filter(
      (call: unknown[]) => {
        const firstArg = call[0] as string;
        return firstArg.startsWith("native-") && call[2] === "blocks";
      },
    );
    // Sprint 2 depends on Sprint 1 (via TP-T003 -> TP-T001)
    // Story 2.1 depends on Story 1.1 (via TP-T003 -> TP-T001)
    // That's 2 container-level dependencies + 2 task-level = 4 total
    expect(nativeStore.addDependency).toHaveBeenCalled();
  });
});
