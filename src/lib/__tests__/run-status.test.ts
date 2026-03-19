import { describe, it, expect } from "vitest";
import { mapRunStatusToSeedStatus } from "../run-status.js";

describe("mapRunStatusToSeedStatus", () => {
  it("maps pending to in_progress", () => {
    expect(mapRunStatusToSeedStatus("pending")).toBe("in_progress");
  });
  it("maps running to in_progress", () => {
    expect(mapRunStatusToSeedStatus("running")).toBe("in_progress");
  });
  it("maps completed to in_progress — waiting for merge, not yet closed", () => {
    expect(mapRunStatusToSeedStatus("completed")).toBe("in_progress");
  });
  it("maps merged to closed", () => {
    expect(mapRunStatusToSeedStatus("merged")).toBe("closed");
  });
  it("maps pr-created to closed", () => {
    expect(mapRunStatusToSeedStatus("pr-created")).toBe("closed");
  });
  it("maps failed to open", () => {
    expect(mapRunStatusToSeedStatus("failed")).toBe("open");
  });
  it("maps stuck to open", () => {
    expect(mapRunStatusToSeedStatus("stuck")).toBe("open");
  });
  it("maps conflict to open", () => {
    expect(mapRunStatusToSeedStatus("conflict")).toBe("open");
  });
  it("maps test-failed to open", () => {
    expect(mapRunStatusToSeedStatus("test-failed")).toBe("open");
  });
  it("maps unknown status to open (safe default)", () => {
    expect(mapRunStatusToSeedStatus("unknown-status")).toBe("open");
  });
  it("completed does NOT map to closed — bead stays visible until merge lands", () => {
    expect(mapRunStatusToSeedStatus("completed")).not.toBe("closed");
  });
});
