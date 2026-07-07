import { describe, expect, it } from "vitest";
import { mapRunStatusToNativeTaskStatus } from "../run-status.js";

describe("mapRunStatusToNativeTaskStatus", () => {
  it("maps active runs to in-progress", () => {
    expect(mapRunStatusToNativeTaskStatus("pending")).toBe("in-progress");
    expect(mapRunStatusToNativeTaskStatus("running")).toBe("in-progress");
  });

  it("maps terminal success states to closed", () => {
    expect(mapRunStatusToNativeTaskStatus("merged")).toBe("closed");
    expect(mapRunStatusToNativeTaskStatus("pr-created")).toBe("closed");
  });

  it("maps retryable or intervention states to native task statuses", () => {
    expect(mapRunStatusToNativeTaskStatus("completed")).toBe("review");
    expect(mapRunStatusToNativeTaskStatus("stuck")).toBe("ready");
    expect(mapRunStatusToNativeTaskStatus("cooldown")).toBe("cooldown");
    expect(mapRunStatusToNativeTaskStatus("conflict")).toBe("blocked");
    expect(mapRunStatusToNativeTaskStatus("test-failed")).toBe("blocked");
    expect(mapRunStatusToNativeTaskStatus("failed")).toBe("failed");
    expect(mapRunStatusToNativeTaskStatus("reset")).toBe("ready");
  });
});
