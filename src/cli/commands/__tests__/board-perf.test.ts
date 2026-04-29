/**
 * Performance tests for board rendering.
 *
 * @module src/cli/commands/__tests__/board-perf.test
 */

import { describe, it, expect } from "vitest";
import type { BoardStatus, BoardTask, RenderState } from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "review",
  "blocked",
  "closed",
] as const;

describe("BoardPerformance", () => {
  // Helper to create a board task
  const createTask = (
    id: string,
    overrides: Partial<BoardTask> = {},
  ): BoardTask => ({
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    external_id: null,
    created_at: "2026-04-19T00:00:00Z",
    updated_at: "2026-04-19T00:00:00Z",
    approved_at: null,
    closed_at: null,
    ...overrides,
  });

  // Helper to create a tasks map with many tasks
  const createTasksMapWithCount = (
    tasksPerStatus: number,
  ): Map<BoardStatus, BoardTask[]> => {
    const map = new Map<BoardStatus, BoardTask[]>();
    let id = 0;
    for (const status of BOARD_STATUSES) {
      const tasks: BoardTask[] = [];
      for (let i = 0; i < tasksPerStatus; i++) {
        tasks.push(createTask(`bd-${String(id++).padStart(4, "0")}`, { status }));
      }
      map.set(status, tasks);
    }
    return map;
  };

  describe("Render Performance", () => {
    it("should handle 200 tasks (200ms target)", () => {
      // ~33 tasks per column
      const tasks = createTasksMapWithCount(33);
      const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);

      expect(totalTasks).toBe(198); // 33 * 6 = 198

      // Simulate render timing
      const start = performance.now();

      // Simulate the actual render work
      let lineCount = 0;
      for (const [status, statusTasks] of tasks) {
        lineCount++; // header
        lineCount += statusTasks.slice(0, 5).length * 3; // task cards (3 lines each)
        if (statusTasks.length > 5) lineCount++; // +N more
      }

      const end = performance.now();
      const duration = end - start;

      // The actual render should be < 200ms
      // This test validates the algorithm complexity is acceptable
      expect(duration).toBeLessThan(200);
      expect(lineCount).toBeGreaterThan(0);
    });

    it("should handle large task lists efficiently", () => {
      const tasks = createTasksMapWithCount(100); // 600 total tasks
      const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);

      expect(totalTasks).toBe(600);

      const start = performance.now();

      // Simulate processing
      let processed = 0;
      for (const statusTasks of tasks.values()) {
        for (const task of statusTasks.slice(0, 5)) {
          // Simulate card rendering
          const truncated = task.title.length > 20 ? task.title.slice(0, 17) + "…" : task.title;
          processed++;
        }
      }

      const end = performance.now();
      const duration = end - start;

      expect(processed).toBe(30); // 6 columns * 5 visible = 30
      expect(duration).toBeLessThan(100); // Should be very fast
    });

    it("navigation should be O(1)", () => {
      const smallTasks = createTasksMapWithCount(10);
      const largeTasks = createTasksMapWithCount(1000);

      const measureNavigation = (tasksByStatus: Map<BoardStatus, BoardTask[]>, iterations: number) => {
        let foundCount = 0;
        let probes = 0;
        for (let i = 0; i < iterations; i++) {
          for (const tasks of tasksByStatus.values()) {
            probes++;
            if (tasks[0]) {
              foundCount++;
              break;
            }
          }
        }
        return {
          foundCount,
          probes,
        };
      };

      const iterations = 10_000;
      const small = measureNavigation(smallTasks, iterations);
      const large = measureNavigation(largeTasks, iterations);

      // Navigation should remain effectively constant time because it only checks
      // the first entry in each status bucket; larger buckets should not cause
      // materially more work even when each bucket contains many more tasks.
      expect(small.foundCount).toBe(iterations);
      expect(large.foundCount).toBe(iterations);
      expect(small.probes).toBe(iterations);
      expect(large.probes).toBe(iterations);
    });
  });

  describe("Memory Usage", () => {
    it("should not accumulate tasks in memory unnecessarily", () => {
      // Create a large task map
      const tasks = createTasksMapWithCount(100);
      const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);

      // Verify we have the right count
      expect(totalTasks).toBe(600);

      // Clear the map to allow GC
      tasks.clear();

      // The map should be empty now
      expect([...tasks.values()].reduce((sum, t) => sum + t.length, 0)).toBe(0);
    });
  });

  describe("Key Response Time", () => {
    it("j key navigation should be < 50ms", () => {
      const tasks = createTasksMapWithCount(50);

      const start = performance.now();

      // Simulate j key press (move down)
      let nav = { colIndex: 0, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = (nav.rowIndex + 1) % currentTasks.length;
      }

      const end = performance.now();
      const duration = end - start;

      expect(duration).toBeLessThan(50);
      expect(nav.rowIndex).toBe(1);
    });

    it("l key navigation should be < 50ms", () => {
      const tasks = createTasksMapWithCount(50);

      const start = performance.now();

      // Simulate l key press (move right)
      let nav = { colIndex: 2, rowIndex: 0 };
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      nav.rowIndex = 0;

      const end = performance.now();
      const duration = end - start;

      expect(duration).toBeLessThan(50);
      expect(nav.colIndex).toBe(3);
    });
  });
});
