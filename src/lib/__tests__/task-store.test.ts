/**
 * task-store.test.ts — Tests for NativeTaskStore.getChildren() method.
 *
 * Verifies that getChildren returns parent-child rows in insertion order
 * as specified in the task_dependencies table.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { NativeTaskStore } from "../task-store.js";

describe("NativeTaskStore.getChildren()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function createMockStore(rows: Array<{ from_task_id: string }>) {
    const mockAll = vi.fn().mockReturnValue(rows);
    const mockPrepare = vi.fn().mockReturnValue({ all: mockAll });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const mockDb = { prepare: mockPrepare } as any;
    const store = new NativeTaskStore(mockDb);
    return { store, mockPrepare, mockAll };
  }

  it("returns child task IDs for a parent task", async () => {
    const rows = [
      { from_task_id: "child-1" },
      { from_task_id: "child-2" },
      { from_task_id: "child-3" },
    ];
    const { store } = createMockStore(rows);

    const children = await store.getChildren("epic-1");

    expect(children).toEqual(["child-1", "child-2", "child-3"]);
  });

  it("returns children in insertion order (by rowid)", async () => {
    // Simulate insertion order via rowid ordering
    const rows = [
      { from_task_id: "child-first" },
      { from_task_id: "child-second" },
      { from_task_id: "child-third" },
      { from_task_id: "child-fourth" },
    ];
    const { store } = createMockStore(rows);

    const children = await store.getChildren("epic-ordered");

    // Verify the ORDER BY rowid ASC is used (insertion order preserved)
    expect(children).toEqual([
      "child-first",
      "child-second",
      "child-third",
      "child-fourth",
    ]);
  });

  it("returns empty array when parent has no children", async () => {
    const { store } = createMockStore([]);

    const children = await store.getChildren("epic-empty");

    expect(children).toEqual([]);
  });

  it("queries with correct SQL parameters (parentId and type='parent-child')", async () => {
    const rows = [{ from_task_id: "child-1" }];
    const { store, mockPrepare } = createMockStore(rows);

    // Clear mock calls from constructor, then call getChildren
    mockPrepare.mockClear();
    await store.getChildren("epic-test");

    expect(mockPrepare).toHaveBeenCalledWith(
      expect.stringContaining("SELECT from_task_id"),
    );
    expect(mockPrepare).toHaveBeenCalledWith(
      expect.stringContaining("WHERE to_task_id = ?"),
    );
    expect(mockPrepare).toHaveBeenCalledWith(
      expect.stringContaining("AND type = 'parent-child'"),
    );
    expect(mockPrepare).toHaveBeenCalledWith(
      expect.stringContaining("ORDER BY rowid ASC"),
    );
  });

  it("passes parentId as the query parameter", async () => {
    const rows = [{ from_task_id: "child-a" }];
    const { store, mockAll } = createMockStore(rows);

    await store.getChildren("epic-test-param");

    // Verify the mock all() was called with the parent ID
    expect(mockAll).toHaveBeenCalledWith("epic-test-param");
  });

  it("maps result rows to child ID array", async () => {
    const rows = [
      { from_task_id: "child-a" },
      { from_task_id: "child-b" },
    ];
    const { store } = createMockStore(rows);

    const children = await store.getChildren("epic-map");

    expect(children).toBeInstanceOf(Array);
    expect(children).toHaveLength(2);
    expect(children[0]).toBe("child-a");
    expect(children[1]).toBe("child-b");
  });
});
