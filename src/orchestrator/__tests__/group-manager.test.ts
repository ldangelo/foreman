import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { GroupManager } from "../group-manager.js";
import type { SeedsClient } from "../../lib/seeds.js";

// Mock SeedsClient
const createMockSeeds = (statusMap: Record<string, string> = {}): SeedsClient => ({
  show: vi.fn(async (seedId: string) => ({
    id: seedId,
    title: `Seed ${seedId}`,
    status: statusMap[seedId] ?? "open",
    type: "task",
    priority: "P2",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    description: null,
    notes: null,
    acceptance: null,
    design: null,
    dependencies: [],
    children: [],
  })),
  close: vi.fn(async () => {}),
} as unknown as SeedsClient);

describe("GroupManager", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-group-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  describe("checkAndAutoClose", () => {
    it("returns false when group has no members", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "empty-group");
      const seeds = createMockSeeds();
      const manager = new GroupManager(store, seeds);

      const result = await manager.checkAndAutoClose(group);
      expect(result).toBe(false);
    });

    it("returns false when not all members are done", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "partial-group");
      store.addGroupMember(group.id, "seed-1");
      store.addGroupMember(group.id, "seed-2");

      const seeds = createMockSeeds({ "seed-1": "closed", "seed-2": "open" });
      const manager = new GroupManager(store, seeds);

      const result = await manager.checkAndAutoClose(group);
      expect(result).toBe(false);
      expect(store.getGroup(group.id)!.status).toBe("active");
    });

    it("auto-closes group when all members are done", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "complete-group");
      store.addGroupMember(group.id, "seed-1");
      store.addGroupMember(group.id, "seed-2");

      const seeds = createMockSeeds({ "seed-1": "closed", "seed-2": "completed" });
      const manager = new GroupManager(store, seeds);

      const result = await manager.checkAndAutoClose(group);
      expect(result).toBe(true);
      expect(store.getGroup(group.id)!.status).toBe("completed");
      expect(store.getGroup(group.id)!.completed_at).toBeDefined();
    });

    it("closes parent seed when group auto-closes", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "epic-group", "epic-seed-1");
      store.addGroupMember(group.id, "seed-1");

      const mockClose = vi.fn(async () => {});
      const seeds = {
        show: vi.fn(async (id: string) => ({
          id, title: `Seed ${id}`, status: "closed", type: "task", priority: "P2",
          assignee: null, parent: null, created_at: "", updated_at: "",
          description: null, notes: null, acceptance: null, design: null,
          dependencies: [], children: [],
        })),
        close: mockClose,
      } as unknown as SeedsClient;

      const manager = new GroupManager(store, seeds);
      await manager.checkAndAutoClose(group);

      expect(mockClose).toHaveBeenCalledWith(
        "epic-seed-1",
        expect.stringContaining("epic-group")
      );
    });

    it("does not re-close an already completed group", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "done-group");
      store.updateGroup(group.id, { status: "completed", completed_at: new Date().toISOString() });

      const completedGroup = store.getGroup(group.id)!;
      const seeds = createMockSeeds();
      const manager = new GroupManager(store, seeds);

      const result = await manager.checkAndAutoClose(completedGroup);
      expect(result).toBe(false);
    });
  });

  describe("getGroupStatus", () => {
    it("returns null for non-existent group", async () => {
      const seeds = createMockSeeds();
      const manager = new GroupManager(store, seeds);
      const result = await manager.getGroupStatus("nonexistent");
      expect(result).toBeNull();
    });

    it("returns progress stats", async () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "test-group");
      store.addGroupMember(group.id, "seed-1");
      store.addGroupMember(group.id, "seed-2");
      store.addGroupMember(group.id, "seed-3");

      const seeds = createMockSeeds({
        "seed-1": "closed",
        "seed-2": "closed",
        "seed-3": "open",
      });
      const manager = new GroupManager(store, seeds);

      const status = await manager.getGroupStatus(group.id);
      expect(status).not.toBeNull();
      expect(status!.total).toBe(3);
      expect(status!.completed).toBe(2);
      expect(status!.progress).toBe(67); // Math.round(2/3*100)
    });
  });

  describe("checkAllGroups", () => {
    it("closes all fully-completed active groups", async () => {
      const project = store.registerProject("p", "/p");

      const g1 = store.createGroup(project.id, "group-1");
      store.addGroupMember(g1.id, "seed-1");

      const g2 = store.createGroup(project.id, "group-2");
      store.addGroupMember(g2.id, "seed-2");
      store.addGroupMember(g2.id, "seed-3"); // seed-3 not done

      const seeds = createMockSeeds({
        "seed-1": "closed",
        "seed-2": "closed",
        "seed-3": "open",
      });
      const manager = new GroupManager(store, seeds);

      const closed = await manager.checkAllGroups(project.id);
      expect(closed).toHaveLength(1);
      expect(closed[0].id).toBe(g1.id);
      expect(store.getGroup(g1.id)!.status).toBe("completed");
      expect(store.getGroup(g2.id)!.status).toBe("active");
    });
  });
});
