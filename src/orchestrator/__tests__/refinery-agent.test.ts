import { describe, it, expect, vi, beforeEach } from "vitest";

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { RefineryAgent, type RefineryAgentConfig } from "../refinery-agent.js";
import type { MergeQueueEntry } from "../merge-queue.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

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

beforeEach(() => {
  mockExecFile.mockReset();
  mockExecFile.mockImplementation((_file: string, _args: string[], _opts: unknown, callback: (err: Error | null, result?: { stdout: string; stderr?: string }) => void) => {
    callback(new Error("exec failed"));
  });
});

describe("RefineryAgent", () => {
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
  });

  describe("checkCiStatus()", () => {
    it("returns true when the first status check conclusion is SUCCESS", async () => {
      mockExecFile.mockImplementation((_file: string, _args: string[], _opts: unknown, callback: (err: Error | null, result?: { stdout: string; stderr?: string }) => void) => {
        callback(null, { stdout: "SUCCESS\n" });
      });

      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      const result = await (agent as any).checkCiStatus(makeEntry());

      expect(result).toBe(true);
      expect(mockExecFile).toHaveBeenCalledWith(
        "gh",
        expect.arrayContaining([
          "pr", "view", "foreman/test-seed",
          "--json", "statusCheckRollup",
          "--jq", ".statusCheckRollup[0].conclusion // \"pending\"",
        ]),
        expect.any(Object),
        expect.any(Function),
      );
    });

    it("returns false when CI is not passing", async () => {
      mockExecFile.mockImplementation((_file: string, _args: string[], _opts: unknown, callback: (err: Error | null, result?: { stdout: string; stderr?: string }) => void) => {
        callback(null, { stdout: "PENDING\n" });
      });

      const mergeQueue = makeMockMergeQueue();
      const vcsBackend = makeMockVcsBackend();
      const agent = new RefineryAgent(mergeQueue as never, vcsBackend, "/tmp/test");

      const result = await (agent as any).checkCiStatus(makeEntry());

      expect(result).toBe(false);
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
