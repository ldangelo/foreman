import { describe, it, expect } from "vitest";
import { mapRunStatusToNativeTaskStatus, mapRunStatusToSeedStatus } from "../run-status.js";

describe("mapRunStatusToSeedStatus", () => {
  it("maps pending to in_progress", () => {
    expect(mapRunStatusToSeedStatus("pending")).toBe("in_progress");
  });
  it("maps running to in_progress", () => {
    expect(mapRunStatusToSeedStatus("running")).toBe("in_progress");
  });
  it("maps completed to review — pipeline done, awaiting merge (not yet closed)", () => {
    expect(mapRunStatusToSeedStatus("completed")).toBe("review");
  });
  it("maps merged to closed", () => {
    expect(mapRunStatusToSeedStatus("merged")).toBe("closed");
  });
  it("maps pr-created to closed", () => {
    expect(mapRunStatusToSeedStatus("pr-created")).toBe("closed");
  });
  it("maps failed to failed — unexpected pipeline exception", () => {
    expect(mapRunStatusToSeedStatus("failed")).toBe("failed");
  });
  it("maps stuck to open — agent pipeline stuck, safe to retry", () => {
    expect(mapRunStatusToSeedStatus("stuck")).toBe("open");
  });
  it("maps conflict to blocked — merge conflict needs human intervention", () => {
    expect(mapRunStatusToSeedStatus("conflict")).toBe("blocked");
  });
  it("maps test-failed to blocked — post-merge tests failed, needs intervention", () => {
    expect(mapRunStatusToSeedStatus("test-failed")).toBe("blocked");
  });
  it("maps unknown status to open (safe default)", () => {
    expect(mapRunStatusToSeedStatus("unknown-status")).toBe("open");
  });
  it("completed does NOT map to closed — bead stays visible until merge lands", () => {
    expect(mapRunStatusToSeedStatus("completed")).not.toBe("closed");
  });
  it("completed does NOT map to in_progress — visually distinct from actively-running tasks", () => {
    expect(mapRunStatusToSeedStatus("completed")).not.toBe("in_progress");
  });
});

describe("mapRunStatusToNativeTaskStatus", () => {
  it("maps running to in-progress", () => {
    expect(mapRunStatusToNativeTaskStatus("running")).toBe("in-progress");
  });
  it("maps completed to review", () => {
    expect(mapRunStatusToNativeTaskStatus("completed")).toBe("review");
  });
  it("maps merged to closed", () => {
    expect(mapRunStatusToNativeTaskStatus("merged")).toBe("closed");
  });
  it("maps pr-created to closed", () => {
    expect(mapRunStatusToNativeTaskStatus("pr-created")).toBe("closed");
  });
  it("maps conflict to blocked", () => {
    expect(mapRunStatusToNativeTaskStatus("conflict")).toBe("blocked");
  });
  it("maps failed to failed", () => {
    expect(mapRunStatusToNativeTaskStatus("failed")).toBe("failed");
  });
  it("maps stuck to ready", () => {
    expect(mapRunStatusToNativeTaskStatus("stuck")).toBe("ready");
  });
  it("maps unknown statuses to ready", () => {
    expect(mapRunStatusToNativeTaskStatus("mystery")).toBe("ready");
  });
});
