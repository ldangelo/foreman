import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";

const { getTaskOrderMock } = vi.hoisted(() => ({
  getTaskOrderMock: vi.fn(),
}));

vi.mock("../task-ordering.js", () => ({
  getTaskOrder: getTaskOrderMock,
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockResolvedValue({
      name: "git",
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    }),
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: vi.fn().mockImplementation(() => ({
    show: vi.fn().mockResolvedValue({ dependencies: [] }),
  })),
}));

const { Dispatcher } = await import("../dispatcher.js");

type Detail = {
  status: string;
  type?: string;
  title?: string;
  description?: string | null;
  notes?: string | null;
  labels?: string[];
  children?: string[];
  dependents?: string[];
};

interface StoreContext {
  store: ForemanStore;
  tmpDir: string;
}

function setupStore(): StoreContext {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-dispatcher-story-grouping-test-"));
  const dbPath = join(tmpDir, "test.db");
  const store = new ForemanStore(dbPath);
  store.registerProject("test-project", "/tmp");
  return { store, tmpDir };
}

function teardownStore(ctx: StoreContext): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

function makeIssue(issue: Partial<Issue> & Pick<Issue, "id" | "title" | "type">): Issue {
  return {
    priority: "P2",
    status: "open",
    assignee: null,
    parent: null,
    created_at: "",
    updated_at: "",
    ...issue,
  };
}

function makeMockBeadsClient(readyIssues: Issue[], details: Record<string, Detail>): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue(readyIssues),
    show: vi.fn().mockImplementation(async (id: string) => {
      const detail = details[id];
      if (!detail) {
        throw new Error(`Missing mock detail for ${id}`);
      }
      return detail;
    }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

describe("Dispatcher — story-scoped worktree grouping", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
    getTaskOrderMock.mockReset();
  });

  afterEach(() => {
    teardownStore(ctx);
  });

  it("dispatches one grouped worktree for multiple ready tasks under the same story", async () => {
    const storyId = "story-1";
    const task1 = makeIssue({ id: "task-1", title: "Task 1", type: "task", parent: storyId });
    const task2 = makeIssue({ id: "task-2", title: "Task 2", type: "task", parent: storyId });

    getTaskOrderMock.mockResolvedValue([
      { seedId: task1.id, seedTitle: task1.title },
      { seedId: task2.id, seedTitle: task2.title },
    ]);

    const beadsClient = makeMockBeadsClient([task1, task2], {
      [storyId]: {
        status: "open",
        type: "feature",
        title: "Story 1",
        labels: ["kind:story"],
        children: [task1.id, task2.id],
      },
      [task1.id]: { status: "open", type: task1.type, title: task1.title },
      [task2.id]: { status: "open", type: task2.type, title: task2.title },
    });

    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0]).toMatchObject({
      seedId: storyId,
      title: "Story 1",
    });
    expect(new Set(result.dispatched.map((item) => item.worktreePath)).size).toBe(1);
    expect(result.dispatched.map((item) => item.seedId)).not.toContain(task1.id);
    expect(result.dispatched.map((item) => item.seedId)).not.toContain(task2.id);
    expect(getTaskOrderMock).toHaveBeenCalledTimes(1);
    expect(getTaskOrderMock).toHaveBeenCalledWith(storyId, expect.anything(), "/tmp");
  });

  it("dispatches different stories in parallel while keeping one worktree per story", async () => {
    const story1Id = "story-1";
    const story2Id = "story-2";
    const issues = [
      makeIssue({ id: "task-1", title: "Story 1 / Task 1", type: "task", parent: story1Id }),
      makeIssue({ id: "task-2", title: "Story 1 / Task 2", type: "task", parent: story1Id }),
      makeIssue({ id: "task-3", title: "Story 2 / Task 1", type: "task", parent: story2Id }),
      makeIssue({ id: "task-4", title: "Story 2 / Task 2", type: "task", parent: story2Id }),
    ];

    getTaskOrderMock.mockImplementation(async (parentId: string) => {
      if (parentId === story1Id) {
        return [
          { seedId: "task-1", seedTitle: "Story 1 / Task 1" },
          { seedId: "task-2", seedTitle: "Story 1 / Task 2" },
        ];
      }
      if (parentId === story2Id) {
        return [
          { seedId: "task-3", seedTitle: "Story 2 / Task 1" },
          { seedId: "task-4", seedTitle: "Story 2 / Task 2" },
        ];
      }
      return [];
    });

    const beadsClient = makeMockBeadsClient(issues, {
      [story1Id]: {
        status: "open",
        type: "feature",
        title: "Story 1",
        labels: ["kind:story"],
        children: ["task-1", "task-2"],
      },
      [story2Id]: {
        status: "open",
        type: "feature",
        title: "Story 2",
        labels: ["kind:story"],
        children: ["task-3", "task-4"],
      },
      "task-1": { status: "open", type: "task", title: "Story 1 / Task 1" },
      "task-2": { status: "open", type: "task", title: "Story 1 / Task 2" },
      "task-3": { status: "open", type: "task", title: "Story 2 / Task 1" },
      "task-4": { status: "open", type: "task", title: "Story 2 / Task 2" },
    });

    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(2);
    expect(new Set(result.dispatched.map((item) => item.seedId))).toEqual(new Set([story1Id, story2Id]));
    expect(new Set(result.dispatched.map((item) => item.worktreePath)).size).toBe(2);
    expect(result.dispatched.map((item) => item.seedId)).not.toEqual(
      expect.arrayContaining(issues.map((issue) => issue.id)),
    );
    expect(getTaskOrderMock).toHaveBeenCalledTimes(2);
  });

  it("keeps ungrouped ready tasks on per-task worktrees", async () => {
    const task1 = makeIssue({ id: "task-1", title: "Ungrouped Task 1", type: "task" });
    const task2 = makeIssue({ id: "task-2", title: "Ungrouped Task 2", type: "task" });

    const beadsClient = makeMockBeadsClient([task1, task2], {
      [task1.id]: { status: "open", type: task1.type, title: task1.title },
      [task2.id]: { status: "open", type: task2.type, title: task2.title },
    });

    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(2);
    expect(new Set(result.dispatched.map((item) => item.seedId))).toEqual(new Set([task1.id, task2.id]));
    expect(new Set(result.dispatched.map((item) => item.worktreePath)).size).toBe(2);
    expect(getTaskOrderMock).not.toHaveBeenCalled();
  });
});
