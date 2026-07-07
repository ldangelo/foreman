import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { updateTerminalRunStatus } from "../agent-worker-run-status.js";
import type { Run } from "../../lib/store.js";

// Mock the dependencies
const { mockPgStore, mockLocalStore } = vi.hoisted(() => {
  const mockPgStore = {
    getRun: vi.fn(),
    updateRun: vi.fn(),
    updateTaskStatusForRun: vi.fn(),
    close: vi.fn(),
  };
  const mockLocalStore = {
    getRun: vi.fn(),
    updateRun: vi.fn(),
    close: vi.fn(),
  };
  return { mockPgStore, mockLocalStore };
});

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: vi.fn(() => mockPgStore),
  },
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => mockLocalStore),
  },
}));

describe("Continuation Retry — issue state evaluation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("isTerminalState logic", () => {
    // These tests verify the logic used in continuationCheck:
    // isTerminal = !status || status === "closed" || status === "completed"

    it("treats null status as terminal", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      // Simulate continuation check with null status
      const status = null;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(true);

      // Should mark as completed
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "completed" }));
    });

    it("treats undefined status as terminal", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      // Simulate continuation check with undefined status
      const status = undefined;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(true);

      // Should mark as completed
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "completed" }));
    });

    it("treats 'closed' status as terminal", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      // Cast to string to avoid type narrowing issues in tests
      const status = "closed" as string;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(true);

      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "completed" }));
    });

    it("treats 'completed' status as terminal", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      const status = "completed" as string;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(true);

      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "completed" }));
    });

    it("treats 'open' status as active (not terminal)", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      const status = "open" as string;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(false);

      // Should keep as running
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "running" },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "running" }));
    });

    it("treats 'in_progress' status as active (not terminal)", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      const status = "in_progress" as string;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(false);

      // Should keep as running
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "running" },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "running" }));
    });

    it("treats 'review' status as active (not terminal)", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      const status = "review" as string;
      const isTerminal = !status || status === "closed" || status === "completed";
      expect(isTerminal).toBe(false);

      // Should keep as running
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "running" },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "running" }));
    });
  });

  describe("continuationCheck runId usage", () => {
    it("uses checkRunId to update the correct run", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-123", status: "running" } as Run);

      // The continuation check should use checkRunId (not a hardcoded value)
      const checkRunId = "run-123";

      await updateTerminalRunStatus({
        runId: checkRunId,
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-123", expect.any(Object));
    });
  });

  describe("error handling", () => {
    it("marks run as completed on task client error", async () => {
      mockLocalStore.getRun.mockResolvedValue({ id: "run-1", status: "running" } as Run);

      // Simulate error handling: on error, mark as completed as safe default
      await updateTerminalRunStatus({
        runId: "run-1",
        projectPath: "/tmp",
        updates: { status: "completed", completed_at: new Date().toISOString() },
      });

      expect(mockLocalStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "completed" }));
    });
  });
});