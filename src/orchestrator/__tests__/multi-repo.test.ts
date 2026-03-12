import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import { Refinery } from "../refinery.js";
import type { DispatchResult, MergeReport } from "../types.js";

describe("Dispatcher.dispatchMultiRepo", () => {
  it("returns empty results for unregistered projects", async () => {
    const mockStore = {
      getProjectByPath: vi.fn().mockReturnValue(null),
      getActiveRuns: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;
    const mockSeeds = {} as any;

    const dispatcher = new Dispatcher(mockSeeds, mockStore, "/tmp");
    const result = await dispatcher.dispatchMultiRepo({
      projectPaths: ["/repo/frontend", "/repo/backend"],
    });

    expect(result.byProject["/repo/frontend"]).toEqual({ dispatched: [], skipped: [], resumed: [], activeAgents: 0 });
    expect(result.byProject["/repo/backend"]).toEqual({ dispatched: [], skipped: [], resumed: [], activeAgents: 0 });
    expect(result.totalDispatched).toBe(0);
    expect(result.totalSkipped).toBe(0);
  });

  it("aggregates results across multiple projects", async () => {
    const frontendProject = { id: "proj-frontend", name: "frontend", path: "/repo/frontend", status: "active" as const, created_at: "", updated_at: "" };
    const backendProject = { id: "proj-backend", name: "backend", path: "/repo/backend", status: "active" as const, created_at: "", updated_at: "" };

    const mockStore = {
      getProjectByPath: vi.fn((path: string) => {
        if (path === "/repo/frontend") return frontendProject;
        if (path === "/repo/backend") return backendProject;
        return null;
      }),
      getActiveRuns: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;

    // Patch SeedsClient and inner dispatcher to return no ready seeds
    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "ready").mockResolvedValue([]);
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const mockSeeds = {} as any;
    const dispatcher = new Dispatcher(mockSeeds, mockStore, "/tmp");
    const result = await dispatcher.dispatchMultiRepo({
      projectPaths: ["/repo/frontend", "/repo/backend"],
    });

    expect(Object.keys(result.byProject)).toHaveLength(2);
    expect(result.totalDispatched).toBe(0);
  });

  it("respects maxAgentsTotal limit", async () => {
    const projectA = { id: "proj-a", name: "a", path: "/repo/a", status: "active" as const, created_at: "", updated_at: "" };
    const projectB = { id: "proj-b", name: "b", path: "/repo/b", status: "active" as const, created_at: "", updated_at: "" };

    const mockStore = {
      getProjectByPath: vi.fn((path: string) => {
        if (path === "/repo/a") return projectA;
        if (path === "/repo/b") return projectB;
        return null;
      }),
      getActiveRuns: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;

    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "ready").mockResolvedValue([]);
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const mockSeeds = {} as any;
    const dispatcher = new Dispatcher(mockSeeds, mockStore, "/tmp");
    const result = await dispatcher.dispatchMultiRepo({
      projectPaths: ["/repo/a", "/repo/b"],
      maxAgentsTotal: 2,
    });

    // Both projects attempted (total limit not exceeded since 0 dispatched from first)
    expect(Object.keys(result.byProject)).toHaveLength(2);
  });
});

describe("Refinery.mergeMultiRepo", () => {
  it("returns empty results for unregistered projects", async () => {
    const mockStore = {
      getProjectByPath: vi.fn().mockReturnValue(null),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;
    const mockSeeds = {} as any;

    const refinery = new Refinery(mockStore, mockSeeds, "/tmp");
    const result = await refinery.mergeMultiRepo({
      targetBranches: {
        "/repo/frontend": "main",
        "/repo/backend": "develop",
      },
    });

    expect(result.byProject["/repo/frontend"]).toEqual({ merged: [], conflicts: [], testFailures: [] });
    expect(result.byProject["/repo/backend"]).toEqual({ merged: [], conflicts: [], testFailures: [] });
    expect(result.errors).toEqual({});
  });

  it("merges each project with its configured target branch", async () => {
    const frontendProject = { id: "proj-fe", name: "frontend", path: "/repo/frontend", status: "active" as const, created_at: "", updated_at: "" };
    const backendProject = { id: "proj-be", name: "backend", path: "/repo/backend", status: "active" as const, created_at: "", updated_at: "" };

    const mockStore = {
      getProjectByPath: vi.fn((path: string) => {
        if (path === "/repo/frontend") return frontendProject;
        if (path === "/repo/backend") return backendProject;
        return null;
      }),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;

    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "ready").mockResolvedValue([]);
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);
    vi.spyOn(SeedsClient.prototype, "getGraph").mockResolvedValue({ nodes: [], edges: [] });

    const mockSeeds = {} as any;
    const refinery = new Refinery(mockStore, mockSeeds, "/tmp");
    const result = await refinery.mergeMultiRepo({
      targetBranches: {
        "/repo/frontend": "main",
        "/repo/backend": "develop",
      },
    });

    expect(Object.keys(result.byProject)).toHaveLength(2);
    expect(result.byProject["/repo/frontend"]).toEqual({ merged: [], conflicts: [], testFailures: [] });
    expect(result.byProject["/repo/backend"]).toEqual({ merged: [], conflicts: [], testFailures: [] });
    expect(result.errors).toEqual({});
  });

  it("captures project-level merge errors in errors record, not as fake FailedRun", async () => {
    const frontendProject = { id: "proj-fe", name: "frontend", path: "/repo/frontend", status: "active" as const, created_at: "", updated_at: "" };

    const mockStore = {
      getProjectByPath: vi.fn().mockReturnValue(frontendProject),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;

    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "getGraph").mockRejectedValue(new Error("git failure"));

    const mockSeeds = {} as any;
    const refinery = new Refinery(mockStore, mockSeeds, "/tmp");

    // Patch mergeCompleted on the inner Refinery to throw
    const { Refinery: RefineryClass } = await import("../refinery.js");
    vi.spyOn(RefineryClass.prototype, "mergeCompleted").mockRejectedValue(new Error("catastrophic merge failure"));

    const result = await refinery.mergeMultiRepo({
      targetBranches: { "/repo/frontend": "main" },
    });

    // errors record should contain the project path and message
    expect(result.errors["/repo/frontend"]).toBe("catastrophic merge failure");
    // testFailures should NOT contain fake empty-string entries
    expect(result.byProject["/repo/frontend"].testFailures).toHaveLength(0);
  });
});

describe("SeedsClient.readyAcrossRepos", () => {
  it("returns empty seeds for each path on failure", async () => {
    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "ready").mockRejectedValue(new Error("not initialized"));
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);

    const result = await SeedsClient.readyAcrossRepos(["/repo/a", "/repo/b"]);
    expect(result).toHaveLength(2);
    expect(result[0].seeds).toEqual([]);
    expect(result[1].seeds).toEqual([]);
  });

  it("returns seeds from each path", async () => {
    const { SeedsClient } = await import("../../lib/seeds.js");
    const mockSeed = { id: "s-001", title: "Test", type: "task", priority: "P2", status: "ready", assignee: null, parent: null, created_at: "", updated_at: "" };
    vi.spyOn(SeedsClient.prototype, "ready").mockResolvedValue([mockSeed]);
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const result = await SeedsClient.readyAcrossRepos(["/repo/a"]);
    expect(result).toHaveLength(1);
    expect(result[0].projectPath).toBe("/repo/a");
    expect(result[0].seeds).toHaveLength(1);
  });
});

describe("SeedsClient.listAcrossRepos", () => {
  it("returns empty seeds for each path on failure", async () => {
    const { SeedsClient } = await import("../../lib/seeds.js");
    vi.spyOn(SeedsClient.prototype, "list").mockRejectedValue(new Error("not initialized"));
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);

    const result = await SeedsClient.listAcrossRepos(["/repo/a"]);
    expect(result).toHaveLength(1);
    expect(result[0].seeds).toEqual([]);
  });
});
