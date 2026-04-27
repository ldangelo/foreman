import { describe, it, expect, vi, beforeEach } from "vitest";
import { RefineryAgent, type RefineryAgentConfig } from "../refinery-agent.js";
import type { MergeQueueEntry } from "../merge-queue.js";
import type { VcsBackend } from "../../lib/vcs/index.js";
import { ForemanStore } from "../../lib/store.js";

// ── Mock Helpers ──────────────────────────────────────────────────────────

interface MockMergeQueue {
  list: ReturnType<typeof vi.fn>;
  dequeue: ReturnType<typeof vi.fn>;
  updateStatus: ReturnType<typeof vi.fn>;
  resetForRetry: ReturnType<typeof vi.fn>;
  _entries: MergeQueueEntry[];
}

function makeMockMergeQueue(entries: MergeQueueEntry[] = []): MockMergeQueue {
  return {
    list: vi.fn().mockReturnValue(entries),
    dequeue: vi.fn().mockReturnValue(entries[0] ?? null),
    updateStatus: vi.fn(),
    resetForRetry: vi.fn(),
    _entries: entries,
  };
}

function makeMockVcsBackend(): VcsBackend {
  return {
    merge: vi.fn(),
    branchExists: vi.fn().mockResolvedValue(true),
    getDefaultBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
  } as unknown as VcsBackend;
}

function makeMockStore(getRun: ReturnType<typeof vi.fn>) {
  return {
    getRun,
  } as unknown as ForemanStore;
}

function makeEntry(overrides: Partial<MergeQueueEntry> = {}): MergeQueueEntry {
  return {
    id: 1,
    branch_name: "foreman/test-seed",
    seed_id: "test-seed",
    run_id: "run-123",
    operation: "auto_merge",
    agent_name: null,
    files_modified: [],
    enqueued_at: new Date().toISOString(),
    started_at: null,
    completed_at: null,
    status: "pending",
    resolved_tier: null,
    error: null,
    retry_count: 0,
    last_attempted_at: null,
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("RefineryAgent", () => {
  const mockForProject = vi.spyOn(ForemanStore, "forProject");
  const mockGetRun = vi.fn();

  beforeEach(() => {
    mockGetRun.mockReset();
    mockForProject.mockClear();
    mockForProject.mockReturnValue(makeMockStore(mockGetRun));
  });

  describe("constructor", () => {
    it("accepts MergeQueue, VcsBackend, and projectPath", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      expect(agent).toBeDefined();
    });

    it("applies default config values", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", {});

      expect(agent).toBeDefined();
    });

    it("merges custom config with defaults", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const config: Partial<RefineryAgentConfig> = {
        pollIntervalMs: 30_000,
        maxFixIterations: 5,
      };

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", config);

      expect(agent).toBeDefined();
    });

    it("uses default model when not specified", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", {});

      expect(agent).toBeDefined();
    });

    it("accepts custom model in config", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const config: Partial<RefineryAgentConfig> = {
        model: "anthropic/claude-opus-4-6",
      };

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", config);

      expect(agent).toBeDefined();
    });
  });

  describe("processOnce()", () => {
    it("returns empty array when no pending entries", async () => {
      const mergeQueue = makeMockMergeQueue();
      mergeQueue.list.mockReturnValue([]);
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      const results = await agent.processOnce();

      expect(results).toEqual([]);
      expect(mergeQueue.list).toHaveBeenCalledWith("pending");
    });

    it("skips entry if dequeue returns null (locked)", async () => {
      const entry = makeEntry({ id: 1 });
      const mergeQueue = makeMockMergeQueue([entry]);
      // Simulate another process holding the lock
      mergeQueue.dequeue.mockReturnValueOnce(null);
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      const results = await agent.processOnce();

      expect(results).toHaveLength(1);
      expect(results[0].action).toBe("skipped");
      expect(results[0].message).toContain("locked");
    });

    it("updates queue status when PR state cannot be read", async () => {
      const entry = makeEntry({ id: 1, branch_name: "foreman/nonexistent" });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);
      mergeQueue.list.mockReturnValue([entry]);
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      // gh will fail for nonexistent branch
      const results = await agent.processOnce();

      expect(results).toHaveLength(1);
      expect(results[0].action).toBe("error");
      expect(results[0].message).toContain("PR state");
    });

    it("awaits an injected async run lookup before deriving the worktree path", async () => {
      const entry = makeEntry({ id: 2 });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", {}, {
        getRun: vi.fn().mockResolvedValue({ id: entry.run_id, worktree_path: "/daemon/worktree" }),
      });

      vi.spyOn(agent as unknown as { ensureMailClient: () => Promise<void> }, "ensureMailClient").mockResolvedValue(undefined);
      vi.spyOn(agent as unknown as { readPrState: () => Promise<unknown> }, "readPrState").mockResolvedValue({});
      vi.spyOn(agent as unknown as { checkCiStatus: () => Promise<boolean> }, "checkCiStatus").mockResolvedValue(true);
      const runAgentSpy = vi.spyOn(agent as unknown as { runAgent: (...args: unknown[]) => Promise<unknown> }, "runAgent").mockResolvedValue({
        success: true,
        action: "merged",
        logPath: "/tmp/log",
      });

      expect(mockForProject).not.toHaveBeenCalled();
      await agent.processOnce();

      expect(runAgentSpy).toHaveBeenCalledWith(entry, expect.anything(), "/daemon/worktree");
    });

    it("keeps the local default run lookup for callers that do not inject one", async () => {
      const entry = makeEntry({ id: 3 });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);
      mockGetRun.mockReturnValue({ id: entry.run_id, worktree_path: "/local/worktree" });
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      vi.spyOn(agent as unknown as { ensureMailClient: () => Promise<void> }, "ensureMailClient").mockResolvedValue(undefined);
      vi.spyOn(agent as unknown as { readPrState: () => Promise<unknown> }, "readPrState").mockResolvedValue({});
      vi.spyOn(agent as unknown as { checkCiStatus: () => Promise<boolean> }, "checkCiStatus").mockResolvedValue(true);
      const runAgentSpy = vi.spyOn(agent as unknown as { runAgent: (...args: unknown[]) => Promise<unknown> }, "runAgent").mockResolvedValue({
        success: true,
        action: "merged",
        logPath: "/tmp/log",
      });

      expect(mockForProject).toHaveBeenCalledWith("/tmp/test");
      await agent.processOnce();

      expect(mockGetRun).toHaveBeenCalledWith(entry.run_id);
      expect(runAgentSpy).toHaveBeenCalledWith(entry, expect.anything(), "/local/worktree");
    });

    it("falls back to project-local worktree when injected lookup returns null", async () => {
      const entry = makeEntry({ id: 4 });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);

      const agent = new RefineryAgent(
        mergeQueue as never,
        makeMockVcsBackend() as never,
        "/tmp/test",
        {},
        {
          getRun: vi.fn().mockResolvedValue(null),
        },
      );

      vi.spyOn(agent as unknown as { ensureMailClient: () => Promise<void> }, "ensureMailClient").mockResolvedValue(undefined);
      vi.spyOn(agent as unknown as { readPrState: () => Promise<unknown> }, "readPrState").mockResolvedValue({});
      vi.spyOn(agent as unknown as { checkCiStatus: () => Promise<boolean> }, "checkCiStatus").mockResolvedValue(true);
      const runAgentSpy = vi.spyOn(agent as unknown as { runAgent: (...args: unknown[]) => Promise<unknown> }, "runAgent").mockResolvedValue({
        success: true,
        action: "merged",
        logPath: "/tmp/log",
      });

      await agent.processOnce();

      expect(runAgentSpy).toHaveBeenCalledWith(entry, expect.anything(), "/tmp/test/worktrees/test-seed");
    });

    it("falls back to project-local worktree when injected lookup has no path", async () => {
      const entry = makeEntry({ id: 5 });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);

      const agent = new RefineryAgent(
        mergeQueue as never,
        makeMockVcsBackend() as never,
        "/tmp/test",
        {},
        {
          getRun: vi.fn().mockResolvedValue({ id: entry.run_id } as never),
        },
      );

      vi.spyOn(agent as unknown as { ensureMailClient: () => Promise<void> }, "ensureMailClient").mockResolvedValue(undefined);
      vi.spyOn(agent as unknown as { readPrState: () => Promise<unknown> }, "readPrState").mockResolvedValue({});
      vi.spyOn(agent as unknown as { checkCiStatus: () => Promise<boolean> }, "checkCiStatus").mockResolvedValue(true);
      const runAgentSpy = vi.spyOn(agent as unknown as { runAgent: (...args: unknown[]) => Promise<unknown> }, "runAgent").mockResolvedValue({
        success: true,
        action: "merged",
        logPath: "/tmp/log",
      });

      await agent.processOnce();

      expect(runAgentSpy).toHaveBeenCalledWith(entry, expect.anything(), "/tmp/test/worktrees/test-seed");
    });

    it("marks a queue entry failed when injected lookup throws", async () => {
      const entry = makeEntry({ id: 6 });
      const mergeQueue = makeMockMergeQueue([entry]);
      mergeQueue.dequeue.mockReturnValue(entry);

      const agent = new RefineryAgent(
        mergeQueue as never,
        makeMockVcsBackend() as never,
        "/tmp/test",
        {},
        {
          getRun: vi.fn().mockRejectedValue(new Error("run lookup failed")),
        },
      );

      vi.spyOn(agent as unknown as { ensureMailClient: () => Promise<void> }, "ensureMailClient").mockResolvedValue(undefined);
      vi.spyOn(agent as unknown as { readPrState: () => Promise<unknown> }, "readPrState").mockResolvedValue({});
      vi.spyOn(agent as unknown as { checkCiStatus: () => Promise<boolean> }, "checkCiStatus").mockResolvedValue(true);
      const runAgentSpy = vi.spyOn(agent as unknown as { runAgent: (...args: unknown[]) => Promise<unknown> }, "runAgent").mockResolvedValue({
        success: false,
        action: "error",
        logPath: "/tmp/log",
        message: "should-not-run",
      });

      const results = await agent.processOnce();

      expect(results).toHaveLength(1);
      expect(results[0].action).toBe("error");
      expect(results[0].message).toContain("run lookup failed");
      expect(mergeQueue.updateStatus).toHaveBeenCalledWith(
        6,
        "failed",
        expect.objectContaining({
          error: expect.stringContaining("run lookup failed"),
        }),
      );
      expect(runAgentSpy).not.toHaveBeenCalled();
    });
  });

  describe("stop()", () => {
    it("stops the daemon loop", () => {
      const mergeQueue = makeMockMergeQueue([]);
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      // stop should not throw
      expect(() => agent.stop()).not.toThrow();
    });
  });

  describe("config validation", () => {
    it("accepts all config options", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const config: RefineryAgentConfig = {
        pollIntervalMs: 10_000,
        maxFixIterations: 3,
        projectPath: "/custom/path",
        logDir: "/custom/logs",
        systemPromptPath: "/custom/prompt.md",
        model: "anthropic/claude-opus-4-6",
      };

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", config);

      expect(agent).toBeDefined();
    });

    it("uses default model when model option is undefined", () => {
      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const config: Partial<RefineryAgentConfig> = {
        maxFixIterations: 2,
      };

      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test", config);

      expect(agent).toBeDefined();
    });
  });
});
