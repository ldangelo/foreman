/**
 * Tests for src/orchestrator/task-ordering.ts
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { getTaskOrder, CircularDependencyError } from "../task-ordering.js";
import type { BrIssueDetail } from "../../lib/beads-rust.js";

// ── Mock BvClient ──────────────────────────────────────────────────────────

vi.mock("../../lib/bv.js", () => ({
  BvClient: vi.fn().mockImplementation(() => ({
    robotTriage: vi.fn().mockResolvedValue(null),
    robotNext: vi.fn().mockResolvedValue(null),
  })),
}));

// ── Helpers ────────────────────────────────────────────────────────────────

function makeDetail(
  id: string,
  title: string,
  priority: string = "P1",
  deps: string[] = [],
  type: string = "task",
): BrIssueDetail {
  return {
    id,
    title,
    type,
    priority,
    status: "open",
    assignee: null,
    parent: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    description: `Description for ${title}`,
    labels: [],
    estimate_minutes: null,
    dependencies: deps.map((depId) => ({
      id: depId,
      title: depId,
      status: "open",
      priority: 1,
      dependency_type: "blocks",
    })),
    dependents: [],
  };
}

function makeBrClient(details: Map<string, BrIssueDetail>) {
  return {
    show: vi.fn().mockImplementation(async (id: string) => {
      const d = details.get(id);
      if (!d) throw new Error(`Bead ${id} not found`);
      return d;
    }),
    // Stub remaining methods that may be called
    list: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    close: vi.fn(),
    addDependency: vi.fn(),
    addComment: vi.fn(),
    search: vi.fn(),
    ready: vi.fn(),
    syncFlushOnly: vi.fn(),
  } as unknown as Record<string, ReturnType<typeof vi.fn>>;
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe("getTaskOrder", () => {
  it("returns empty array for epic with no children", async () => {
    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = [];
    const details = new Map([["epic-1", epic]]);
    const client = makeBrClient(details);

    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result).toEqual([]);
  });

  it("returns tasks in dependency order (topological sort)", async () => {
    const task1 = makeDetail("t1", "Task 1", "P1", []);
    const task2 = makeDetail("t2", "Task 2", "P1", ["t1"]); // depends on t1
    const task3 = makeDetail("t3", "Task 3", "P1", ["t2"]); // depends on t2

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t1", "t2", "t3"];

    const details = new Map([
      ["epic-1", epic],
      ["t1", task1],
      ["t2", task2],
      ["t3", task3],
    ]);
    const client = makeBrClient(details);

    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result.map((t) => t.seedId)).toEqual(["t1", "t2", "t3"]);
  });

  it("uses priority as tiebreaker when no deps", async () => {
    const taskP0 = makeDetail("t-p0", "Critical", "P0", []);
    const taskP2 = makeDetail("t-p2", "Normal", "P2", []);
    const taskP1 = makeDetail("t-p1", "High", "P1", []);

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t-p2", "t-p0", "t-p1"]; // unordered

    const details = new Map([
      ["epic-1", epic],
      ["t-p0", taskP0],
      ["t-p2", taskP2],
      ["t-p1", taskP1],
    ]);
    const client = makeBrClient(details);

    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result.map((t) => t.seedId)).toEqual(["t-p0", "t-p1", "t-p2"]);
  });

  it("throws CircularDependencyError on circular deps", async () => {
    const task1 = makeDetail("t1", "Task 1", "P1", ["t2"]);
    const task2 = makeDetail("t2", "Task 2", "P1", ["t1"]); // circular!

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t1", "t2"];

    const details = new Map([
      ["epic-1", epic],
      ["t1", task1],
      ["t2", task2],
    ]);
    const client = makeBrClient(details);

    await expect(
      getTaskOrder("epic-1", client as never, "/tmp", false),
    ).rejects.toThrow(CircularDependencyError);
  });

  it("skips feature/story children (only includes task/bug/chore)", async () => {
    const task1 = makeDetail("t1", "Task 1", "P1", [], "task");
    const story = makeDetail("s1", "Story 1", "P1", [], "feature");

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t1", "s1"];

    const details = new Map([
      ["epic-1", epic],
      ["t1", task1],
      ["s1", story],
    ]);
    const client = makeBrClient(details);

    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result).toHaveLength(1);
    expect(result[0].seedId).toBe("t1");
  });

  it("includes seedDescription from bead description", async () => {
    const task1 = makeDetail("t1", "Task 1", "P1", []);

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t1"];

    const details = new Map([
      ["epic-1", epic],
      ["t1", task1],
    ]);
    const client = makeBrClient(details);

    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result[0].seedDescription).toBe("Description for Task 1");
  });

  it("handles mixed deps — some within children, some external", async () => {
    // t2 depends on t1 (internal) and ext-1 (external, not a child of this epic)
    const task1 = makeDetail("t1", "Task 1", "P1", []);
    const task2 = makeDetail("t2", "Task 2", "P1", ["t1", "ext-1"]);

    const epic = makeDetail("epic-1", "Epic", "P1", [], "epic");
    epic.children = ["t1", "t2"];

    const details = new Map([
      ["epic-1", epic],
      ["t1", task1],
      ["t2", task2],
    ]);
    const client = makeBrClient(details);

    // External dep ext-1 is ignored (not in children set), so t2 only depends on t1
    const result = await getTaskOrder("epic-1", client as never, "/tmp", false);
    expect(result.map((t) => t.seedId)).toEqual(["t1", "t2"]);
  });
});
