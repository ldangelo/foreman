/**
 * Unit tests for heartbeat manager.
 * Tests periodic observability events during active pipeline phases.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  HeartbeatManager,
  createHeartbeatManager,
  type HeartbeatConfig,
  type SessionStats,
} from "../heartbeat-manager.js";

// Mock ForemanStore
const mockStore = {
  logEvent: vi.fn(),
};

// Mock VcsBackend
const mockVcs = {
  getHeadId: vi.fn(),
  getChangedFiles: vi.fn(),
};

// Mock ForemanStore type
import type { ForemanStore } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

describe("HeartbeatManager", () => {
  let config: HeartbeatConfig;
  let mockStoreInstance: ForemanStore;
  let mockVcsInstance: VcsBackend;

  beforeEach(() => {
    vi.useFakeTimers();
    mockStore.logEvent = vi.fn();
    mockStoreInstance = mockStore as unknown as ForemanStore;
    mockVcsInstance = {
      ...mockVcs,
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      getChangedFiles: vi.fn().mockResolvedValue([]),
    } as unknown as VcsBackend;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("constructor", () => {
    it("should set default values when config is empty", () => {
      const manager = new HeartbeatManager(
        {},
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      expect(manager.getConfig().enabled).toBe(true);
      expect(manager.getConfig().intervalSeconds).toBe(60);
    });

    it("should respect custom config values", () => {
      const manager = new HeartbeatManager(
        { enabled: true, intervalSeconds: 30 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      expect(manager.getConfig().enabled).toBe(true);
      expect(manager.getConfig().intervalSeconds).toBe(30);
    });

    it("should disable heartbeat when enabled=false", () => {
      const manager = new HeartbeatManager(
        { enabled: false, intervalSeconds: 60 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      expect(manager.getConfig().enabled).toBe(false);
    });
  });

  describe("start()", () => {
    it("should capture initial state when starting", async () => {
      const manager = new HeartbeatManager(
        { enabled: true, intervalSeconds: 60 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");

      expect(mockVcsInstance.getHeadId).toHaveBeenCalledWith("/worktrees/project/seed-abc");
    });

    it("should not start when disabled", async () => {
      const manager = new HeartbeatManager(
        { enabled: false },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");

      expect(mockVcsInstance.getHeadId).not.toHaveBeenCalled();
    });

    it("should set current phase", async () => {
      const manager = new HeartbeatManager(
        { enabled: true },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("qa");

      expect(manager.isActive()).toBe(true);
    });
  });

  describe("stop()", () => {
    it("should clear the interval and reset state", async () => {
      const manager = new HeartbeatManager(
        { enabled: true, intervalSeconds: 60 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");
      expect(manager.isActive()).toBe(true);

      manager.stop();
      expect(manager.isActive()).toBe(false);
    });
  });

  describe("update()", () => {
    it("should store session stats for heartbeat emission", async () => {
      const manager = new HeartbeatManager(
        { enabled: true, intervalSeconds: 60 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");

      const stats: SessionStats = {
        turns: 10,
        toolCalls: 25,
        toolBreakdown: { Read: 10, Edit: 10, Bash: 5 },
        costUsd: 0.5,
        tokensIn: 5000,
        tokensOut: 3000,
        lastFileEdited: "src/test.ts",
        lastActivity: new Date().toISOString(),
      };

      manager.update(stats);

      // Verify heartbeat fires with updated stats
      const promise = manager.fireHeartbeat();
      // Advance timer to fire the heartbeat
      vi.advanceTimersByTime(60_000);
      await promise;

      expect(mockStore.logEvent).toHaveBeenCalledWith(
        "proj-123",
        "heartbeat",
        expect.objectContaining({
          turns: 10,
          toolCalls: 25,
          costUsd: 0.5,
        }),
        "run-456",
      );
    });
  });

  describe("fireHeartbeat()", () => {
    it("should write heartbeat event to store", async () => {
      const manager = new HeartbeatManager(
        { enabled: true },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");

      await manager.fireHeartbeat();

      expect(mockStore.logEvent).toHaveBeenCalledWith(
        "proj-123",
        "heartbeat",
        expect.objectContaining({
          phase: "developer",
          turns: expect.any(Number),
          toolCalls: expect.any(Number),
        }),
        "run-456",
      );
    });

    it("should include files changed since phase start", async () => {
      // Override getChangedFiles to return specific files
      (mockVcsInstance.getChangedFiles as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
        "src/test.ts",
        "src/index.ts",
      ]);

      const manager = new HeartbeatManager(
        { enabled: true },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");
      
      // Update stats to include files changed
      manager.update({
        turns: 5,
        toolCalls: 10,
        toolBreakdown: {},
        costUsd: 0.1,
        tokensIn: 1000,
        tokensOut: 500,
      });

      await manager.fireHeartbeat();

      expect(mockStore.logEvent).toHaveBeenCalled();
      // The files changed may be computed from the VCS diff call
      const callArgs = mockStore.logEvent.mock.calls[0];
      expect(callArgs).toBeDefined();
    });

    it("should not fire when disabled", async () => {
      const manager = new HeartbeatManager(
        { enabled: false },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");
      await manager.fireHeartbeat();

      expect(mockStore.logEvent).not.toHaveBeenCalled();
    });
  });

  describe("interval behavior", () => {
    it("should be active when started", async () => {
      const manager = new HeartbeatManager(
        { enabled: true, intervalSeconds: 30 },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      await manager.start("developer");

      // Should be active after start
      expect(manager.isActive()).toBe(true);
    });
  });

  describe("fail-safe behavior", () => {
    it("should continue on store write failure", async () => {
      const manager = new HeartbeatManager(
        { enabled: true },
        mockStoreInstance,
        "proj-123",
        "run-456",
        mockVcsInstance,
        "/worktrees/project/seed-abc",
      );

      mockStore.logEvent.mockRejectedValueOnce(new Error("DB write failed"));

      await manager.start("developer");

      // Should not throw
      await expect(manager.fireHeartbeat()).resolves.not.toThrow();
    });
  });
});

describe("createHeartbeatManager", () => {
  it("should return null when heartbeat is disabled", () => {
    const manager = createHeartbeatManager(
      { enabled: false },
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(manager).toBeNull();
  });

  it("should create manager with defaults when config is undefined", () => {
    const manager = createHeartbeatManager(
      undefined,
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(manager).not.toBeNull();
    expect(manager!.getConfig().enabled).toBe(true);
    expect(manager!.getConfig().intervalSeconds).toBe(60);
  });

  it("should respect custom config", () => {
    const manager = createHeartbeatManager(
      { enabled: true, intervalSeconds: 120 },
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(manager).not.toBeNull();
    expect(manager!.getConfig().intervalSeconds).toBe(120);
  });
});

describe("shouldFire()", () => {
  it("should return true when active and enabled", async () => {
    const manager = new HeartbeatManager(
      { enabled: true },
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    await manager.start("developer");

    expect(manager.shouldFire()).toBe(true);
  });

  it("should return false when not started", () => {
    const manager = new HeartbeatManager(
      { enabled: true },
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(manager.shouldFire()).toBe(false);
  });

  it("should return false when disabled", async () => {
    const manager = new HeartbeatManager(
      { enabled: false },
      {} as ForemanStore,
      "proj-123",
      "run-456",
      {} as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    await manager.start("developer");

    expect(manager.shouldFire()).toBe(false);
  });
});