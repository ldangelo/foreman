import { describe, it, expect, vi, afterEach } from "vitest";
import { SeedsClient } from "../seeds.js";
import type { Seed } from "../seeds.js";

afterEach(() => {
  vi.restoreAllMocks();
});

const makeSeed = (id: string): Seed => ({
  id,
  title: `Seed ${id}`,
  type: "task",
  priority: "P2",
  status: "ready",
  assignee: null,
  parent: null,
  created_at: "",
  updated_at: "",
});

describe("SeedsClient.readyAcrossRepos", () => {
  it("aggregates results from multiple repos", async () => {
    const spy = vi
      .spyOn(SeedsClient.prototype, "ready")
      .mockImplementationOnce(async () => [makeSeed("s-001")])
      .mockImplementationOnce(async () => [makeSeed("s-002"), makeSeed("s-003")]);

    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const result = await SeedsClient.readyAcrossRepos(["/repo/a", "/repo/b"]);

    expect(result).toHaveLength(2);
    expect(result[0].projectPath).toBe("/repo/a");
    expect(result[0].seeds).toHaveLength(1);
    expect(result[1].projectPath).toBe("/repo/b");
    expect(result[1].seeds).toHaveLength(2);
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("returns empty seeds array for a failing repo and continues", async () => {
    vi.spyOn(SeedsClient.prototype, "ready")
      .mockRejectedValueOnce(new Error("seed CLI not found"))
      .mockResolvedValueOnce([makeSeed("s-001")]);

    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const result = await SeedsClient.readyAcrossRepos(["/repo/broken", "/repo/ok"]);

    expect(result).toHaveLength(2);
    expect(result[0].seeds).toEqual([]);
    expect(result[1].seeds).toHaveLength(1);
  });

  it("returns empty array for empty projectPaths input", async () => {
    const result = await SeedsClient.readyAcrossRepos([]);
    expect(result).toEqual([]);
  });
});

describe("SeedsClient.listAcrossRepos", () => {
  it("passes opts to each client's list()", async () => {
    const spy = vi.spyOn(SeedsClient.prototype, "list").mockResolvedValue([makeSeed("s-001")]);
    vi.spyOn(SeedsClient.prototype, "ensureSdInstalled").mockResolvedValue(undefined);
    vi.spyOn(SeedsClient.prototype, "isInitialized").mockResolvedValue(true);

    const result = await SeedsClient.listAcrossRepos(["/repo/a"], { status: "in_progress" });

    expect(result).toHaveLength(1);
    expect(result[0].seeds).toHaveLength(1);
    expect(spy).toHaveBeenCalledWith({ status: "in_progress" });
  });
});
