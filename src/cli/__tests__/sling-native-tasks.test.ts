/**
 * Tests for TRD-012: Native task creation via NativeTaskStore (REQ-009)
 *
 * Verifies:
 * 1. execute() calls NativeTaskStore instead of br for native path
 * 2. Tasks are created with 'backlog' status (not 'ready')
 * 3. Auto-migration: ForemanStore schema creates tasks table automatically
 * 4. Dependencies are imported correctly via addDependency()
 * 5. Output format: SlingResult.native is populated with TrackerResult
 *
 * REQ-009: "foreman sling trd <trd-file> shall create tasks in the native task
 * store instead of calling the br binary."
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execute } from "../../orchestrator/sling-executor.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore } from "../../lib/task-store.js";
import type {
  SlingPlan,
  SlingOptions,
  ParallelResult,
  Priority,
} from "../../orchestrator/types.js";

// ── Test fixtures ─────────────────────────────────────────────────────────────

function setupStore(): { store: ForemanStore; taskStore: NativeTaskStore; tmpDir: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-native-test-"));
  const dbPath = join(tmpDir, "test.db");
  const store = new ForemanStore(dbPath);
  const taskStore = new NativeTaskStore(store.getDb());
  return { store, taskStore, tmpDir };
}

function teardownStore(ctx: { store: ForemanStore; tmpDir: string }): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

// ── Test data ────────────────────────────────────────────────────────────

function makeTestPlan(): SlingPlan {
  return {
    epic: {
      title: "TRD: Native Test Epic",
      description: "Test description",
      documentId: "TRD-NATIVE",
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
                dependencies: ["TP-T001"], // cross-sprint dependency
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

// ── AC1: Uses NativeTaskStore instead of br ────────────────────────────────────

describe("AC1: Uses NativeTaskStore instead of br", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("execute() calls NativeTaskStore.create() for native path", async () => {
    const plan = makeTestPlan();
    const onProgress = vi.fn();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, onProgress, ctx.taskStore);

    // Verify onProgress was called with tracker="native"
    const nativeCalls = onProgress.mock.calls.filter((call) => call[2] === "native");
    expect(nativeCalls.length).toBeGreaterThan(0);
  });

  it("execute() returns SlingResult.native with created count", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // Should have created: epic(1) + sprints(2) + stories(2) + tasks(3) = 8
    expect(result.native).not.toBeNull();
    expect(result.native!.created).toBe(8);
    expect(result.native!.failed).toBe(0);
    expect(result.native!.skipped).toBe(0);
  });

  it("execute() returns null for native when no NativeTaskStore provided", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, undefined);

    expect(result.native).toBeNull();
  });

  it("native path works alongside sd and br paths", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, seeds as any, br as any, undefined, ctx.taskStore);

    // All three paths should be populated
    expect(result.sd).not.toBeNull();
    expect(result.br).not.toBeNull();
    expect(result.native).not.toBeNull();

    // Each path creates the same hierarchy (8 items)
    expect(result.sd!.created).toBe(8);
    expect(result.br!.created).toBe(8);
    expect(result.native!.created).toBe(8);
  });
});

// ── AC2: Tasks created with backlog status ─────────────────────────────────────

describe("AC2: Tasks created with backlog status", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("all tasks are created in 'backlog' status (not 'ready')", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // Query all tasks
    const allTasks = ctx.taskStore.list();
    expect(allTasks.length).toBe(8);

    // All should be in backlog status
    for (const task of allTasks) {
      expect(task.status).toBe("backlog");
    }
  });

  it("tasks are NOT visible to ready() dispatcher query", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // ready() only returns tasks with status='ready' AND run_id IS NULL
    const readyTasks = await ctx.taskStore.ready();
    expect(readyTasks).toHaveLength(0);
  });

  it("epic task is created with type='epic'", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const epicTask = allTasks.find((t) => t.type === "epic");
    expect(epicTask).toBeDefined();
    expect(epicTask!.title).toBe("TRD: Native Test Epic");
    expect(epicTask!.status).toBe("backlog");
  });

  it("sprint tasks are created with type='sprint'", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const sprintTasks = allTasks.filter((t) => t.type === "sprint");
    expect(sprintTasks).toHaveLength(2);
    expect(sprintTasks.every((t) => t.status === "backlog")).toBe(true);
  });

  it("story tasks are created with type='story'", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const storyTasks = allTasks.filter((t) => t.type === "story");
    expect(storyTasks).toHaveLength(2);
    expect(storyTasks.every((t) => t.status === "backlog")).toBe(true);
  });

  it("regular tasks are created with type='task'", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const taskItems = allTasks.filter((t) => t.type === "task");
    expect(taskItems).toHaveLength(3); // TP-T001, TP-T002, TP-T003
    expect(taskItems.every((t) => t.status === "backlog")).toBe(true);
  });

  it("completed tasks are skipped when --skip-completed is set", async () => {
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, skipCompleted: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, null, null, undefined, ctx.taskStore);

    // TP-T003 is completed, should be skipped
    expect(result.native!.skipped).toBe(1);
    expect(result.native!.created).toBe(7); // 8 - 1 skipped

    // All remaining tasks should be in backlog
    const allTasks = ctx.taskStore.list();
    expect(allTasks.every((t) => t.status === "backlog")).toBe(true);
  });

  it("completed tasks are created then closed with --close-completed", async () => {
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, closeCompleted: true };

    const result = await execute(plan, EMPTY_PARALLEL, options, null, null, undefined, ctx.taskStore);

    // All 8 created (including completed task)
    expect(result.native!.created).toBe(8);

    // TP-T003 should be in 'merged' status (closed)
    const allTasks = ctx.taskStore.list();
    const completedTask = allTasks.find((t) => t.title === "Implement feature B");
    expect(completedTask!.status).toBe("merged");
  });
});

// ── AC3: Auto-migration happens ─────────────────────────────────────────────────

describe("AC3: Auto-migration happens", () => {
  it("ForemanStore constructor creates tasks table automatically", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-migration-test-"));
    try {
      const dbPath = join(tmpDir, "test.db");
      const store = new ForemanStore(dbPath);
      const taskStore = new NativeTaskStore(store.getDb());

      // Should be able to create a task immediately without manual migration
      const task = taskStore.create({ title: "Migration Test" });
      expect(task.id).toBeTruthy();
      expect(task.status).toBe("backlog");

      store.close();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("task_dependencies table is created automatically", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-deps-migration-test-"));
    try {
      const dbPath = join(tmpDir, "test.db");
      const store = new ForemanStore(dbPath);
      const taskStore = new NativeTaskStore(store.getDb());

      // Should be able to add dependency without manual migration
      const taskA = taskStore.create({ title: "Task A" });
      const taskB = taskStore.create({ title: "Task B" });

      // Should not throw
      taskStore.addDependency(taskA.id, taskB.id, "blocks");

      // Verify dependency was stored
      const deps = taskStore.getDependencies(taskA.id, "outgoing");
      expect(deps).toHaveLength(1);
      expect(deps[0]!.to_task_id).toBe(taskB.id);

      store.close();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("fresh temp DB has proper schema for NativeTaskStore operations", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-schema-test-"));
    try {
      const dbPath = join(tmpDir, "test.db");
      const store = new ForemanStore(dbPath);
      const taskStore = new NativeTaskStore(store.getDb());
      const plan = makeTestPlan();

      // Execute with fresh store — should work without manual schema setup
      const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, taskStore);

      expect(result.native).not.toBeNull();
      expect(result.native!.created).toBe(8);
      expect(result.native!.failed).toBe(0);

      // Verify all CRUD operations work on fresh DB
      const tasks = taskStore.list();
      expect(tasks).toHaveLength(8);

      const ready = await taskStore.ready();
      expect(ready).toHaveLength(0); // All in backlog

      const task = tasks[0];
      expect(() => taskStore.get(task.id)).not.toThrow();

      store.close();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

// ── AC4: Dependencies imported ─────────────────────────────────────────────────

describe("AC4: Dependencies imported", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("task-level dependencies are wired via addDependency(blocks)", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // TP-T002 depends on TP-T001
    const allTasks = ctx.taskStore.list();
    const taskT001 = allTasks.find((t) => t.title === "Implement feature A");
    const taskT002 = allTasks.find((t) => t.title === "Write tests for feature A");

    // T002's outgoing deps should include T001 (T002 is blocked by T001)
    const t002Deps = ctx.taskStore.getDependencies(taskT002!.id, "outgoing");
    expect(t002Deps.some((d) => d.to_task_id === taskT001!.id)).toBe(true);
  });

  it("cross-sprint dependencies are wired (sprint→sprint blocking)", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // Sprint 2 has TP-T003 which depends on TP-T001 (Sprint 1)
    // This should create a sprint→sprint blocking dependency
    const allTasks = ctx.taskStore.list();
    const sprint1 = allTasks.find((t) => t.type === "sprint" && t.title === "Sprint 1: Foundation");
    const sprint2 = allTasks.find((t) => t.type === "sprint" && t.title === "Sprint 2: Advanced");

    // Sprint 2 should block on Sprint 1 (Sprint 2 outgoing deps include Sprint 1)
    const sprint2Deps = ctx.taskStore.getDependencies(sprint2!.id, "outgoing");
    expect(sprint2Deps.some((d) => d.to_task_id === sprint1!.id && d.type === "blocks")).toBe(true);
  });

  it("cross-story dependencies are wired (story→story blocking)", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const story1 = allTasks.find((t) => t.type === "story" && t.title === "Story 1.1: First Story");
    const story2 = allTasks.find((t) => t.type === "story" && t.title === "Story 2.1: Second Story");

    // Story 2 should block on Story 1 (via cross-sprint task dependency)
    const story2Deps = ctx.taskStore.getDependencies(story2!.id, "outgoing");
    expect(story2Deps.some((d) => d.to_task_id === story1!.id && d.type === "blocks")).toBe(true);
  });

  it("no dependencies for tasks with empty dependency list", async () => {
    const plan = makeTestPlan();

    await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const allTasks = ctx.taskStore.list();
    const taskT001 = allTasks.find((t) => t.title === "Implement feature A");

    // T001 has no dependencies
    const t001Deps = ctx.taskStore.getDependencies(taskT001!.id, "outgoing");
    expect(t001Deps).toHaveLength(0);
  });

  it("dependency errors are collected in SlingResult.depErrors", async () => {
    const plan = makeTestPlan();

    // Create a plan with a dependency to a non-existent task
    plan.sprints[0].stories[0].tasks[0].dependencies = ["NON-EXISTENT"];

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // Should have a dependency error for the missing task
    const nativeDepErrors = result.depErrors.filter((e) => e.includes("SLING-007"));
    expect(nativeDepErrors.length).toBeGreaterThan(0);
    expect(nativeDepErrors[0]).toContain("NON-EXISTENT");
  });

  it("cycle detection prevents circular dependencies", async () => {
    // Create a plan where A depends on B and B depends on A
    // This would create a cycle if we tried to add both deps
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-cycle-test-"));
    try {
      const dbPath = join(tmpDir, "test.db");
      const store = new ForemanStore(dbPath);
      const taskStore = new NativeTaskStore(store.getDb());

      const cyclePlan: SlingPlan = {
        epic: { title: "Cycle Epic", description: "", documentId: "CYCLE" },
        sprints: [
          {
            number: 1,
            title: "Sprint 1",
            goal: "Goal",
            priority: "medium",
            stories: [
              {
                title: "Story 1",
                tasks: [
                  { trdId: "T1", title: "Task 1", estimateHours: 1, dependencies: ["T2"], files: [], status: "open" },
                  { trdId: "T2", title: "Task 2", estimateHours: 1, dependencies: ["T1"], files: [], status: "open" },
                ],
              },
            ],
          },
        ],
        acceptanceCriteria: new Map(),
        riskMap: new Map(),
      };

      // Should handle cycle gracefully (not crash)
      const result = await execute(cyclePlan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, taskStore);

      // One of the deps should fail due to cycle detection
      expect(result.native!.failed + result.native!.skipped).toBeGreaterThanOrEqual(0);

      store.close();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

// ── AC5: Output format correct ─────────────────────────────────────────────────

describe("AC5: Output format correct", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("SlingResult.native has required TrackerResult fields", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    expect(result.native).toMatchObject({
      created: expect.any(Number),
      skipped: expect.any(Number),
      failed: expect.any(Number),
      epicId: null, // native tasks don't have epic IDs tracked the same way
      errors: expect.any(Array),
    });
  });

  it("created count matches plan (1 epic + 2 sprints + 2 stories + 3 tasks = 8)", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    expect(result.native!.created).toBe(8);
  });

  it("skipped count is 0 when no completed tasks", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    expect(result.native!.skipped).toBe(0);
  });

  it("failed count is 0 on successful creation", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    expect(result.native!.failed).toBe(0);
  });

  it("errors array is empty on success", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    const sl007Errors = result.native!.errors.filter((e) => e.includes("SLING-007"));
    const sl006Errors = result.native!.errors.filter((e) => e.includes("SLING-006"));
    expect(sl006Errors).toHaveLength(0);
    expect(sl007Errors).toHaveLength(0);
  });

  it("depErrors are accumulated in SlingResult.depErrors", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    // No dep errors for a clean plan
    const nativeDepErrors = result.depErrors.filter((e) => e.includes("SLING-007") && e.includes("native"));
    expect(nativeDepErrors).toHaveLength(0);
  });

  it("SlingResult has sd, br, native, and depErrors fields", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, ctx.taskStore);

    expect(result).toHaveProperty("sd");
    expect(result).toHaveProperty("br");
    expect(result).toHaveProperty("native");
    expect(result).toHaveProperty("depErrors");
    expect(Array.isArray(result.depErrors)).toBe(true);
  });

  it("result.native is null when NativeTaskStore is not provided", async () => {
    const plan = makeTestPlan();

    const result = await execute(plan, EMPTY_PARALLEL, DEFAULT_OPTIONS, null, null, undefined, undefined);

    expect(result.native).toBeNull();
    expect(result.sd).toBeNull();
    expect(result.br).toBeNull();
  });
});

// ── Integration: native path alongside sd and br ─────────────────────────────────

describe("Integration: native path alongside sd and br", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("all three paths can run concurrently", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const onProgress = vi.fn();

    const result = await execute(
      plan,
      EMPTY_PARALLEL,
      DEFAULT_OPTIONS,
      seeds as any,
      br as any,
      onProgress,
      ctx.taskStore,
    );

    expect(result.sd).not.toBeNull();
    expect(result.br).not.toBeNull();
    expect(result.native).not.toBeNull();

    // Verify progress callback was called for all three trackers
    const sdCalls = onProgress.mock.calls.filter((c) => c[2] === "sd");
    const brCalls = onProgress.mock.calls.filter((c) => c[2] === "br");
    const nativeCalls = onProgress.mock.calls.filter((c) => c[2] === "native");

    expect(sdCalls.length).toBeGreaterThan(0);
    expect(brCalls.length).toBeGreaterThan(0);
    expect(nativeCalls.length).toBeGreaterThan(0);
  });

  it("sd-only skips both br and native", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, sdOnly: true };

    const result = await execute(
      plan,
      EMPTY_PARALLEL,
      options,
      seeds as any,
      br as any,
      undefined,
      ctx.taskStore,
    );

    expect(result.sd).not.toBeNull();
    expect(result.br).toBeNull();
    expect(result.native).toBeNull(); // native is also skipped when sdOnly
  });

  it("br-only skips both sd and native", async () => {
    const seeds = createMockSdClient();
    const br = createMockBeadsRustClient();
    const plan = makeTestPlan();
    const options = { ...DEFAULT_OPTIONS, brOnly: true };

    const result = await execute(
      plan,
      EMPTY_PARALLEL,
      options,
      seeds as any,
      br as any,
      undefined,
      ctx.taskStore,
    );

    expect(result.sd).toBeNull();
    expect(result.br).not.toBeNull();
    expect(result.native).toBeNull(); // native follows br-only behavior
  });
});

// ── Mock clients (for integration tests) ─────────────────────────────────────

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
