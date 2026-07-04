import { describe, expect, it, vi } from "vitest";
import type { RunProgress } from "../../lib/store.js";
import { writeMarkStuckEvent, writeMarkStuckProgress } from "../agent-worker-mark-stuck-observability.js";

const progress: RunProgress = {
  toolCalls: 3,
  toolBreakdown: {},
  filesChanged: [],
  turns: 7,
  costUsd: 1.25,
  tokensIn: 10,
  tokensOut: 20,
  lastToolCall: null,
  lastActivity: new Date().toISOString(),
};

describe("markStuck observability routing", () => {
  it("emits through provided writer when present", async () => {
    const writer = { updateProgress: vi.fn(), logEvent: vi.fn() };
    const logFn = vi.fn();

    await writeMarkStuckProgress(writer, "run-1", progress, logFn);
    await writeMarkStuckEvent(writer, "proj-1", "run-1", "stuck", { taskId: "task-1" }, logFn);

    expect(writer.updateProgress).toHaveBeenCalledWith(progress);
    expect(writer.logEvent).toHaveBeenCalledWith("stuck", { taskId: "task-1" });
    expect(logFn).not.toHaveBeenCalled();
  });

  it("does nothing when no writer is provided", async () => {
    const logFn = vi.fn();

    await writeMarkStuckProgress(undefined, "run-1", progress, logFn);
    await writeMarkStuckEvent(undefined, "proj-1", "run-1", "fail", { reason: "boom" }, logFn);

    expect(logFn).not.toHaveBeenCalled();
  });

  it("logs writer failures without fallback store writes", async () => {
    const writer = {
      updateProgress: vi.fn().mockRejectedValue(new Error("event down")),
      logEvent: vi.fn().mockRejectedValue(new Error("event down")),
    };
    const logFn = vi.fn();

    await writeMarkStuckProgress(writer, "run-1", progress, logFn);
    await writeMarkStuckEvent(writer, "proj-1", "run-1", "fail", { reason: "boom" }, logFn);

    expect(logFn).toHaveBeenCalledWith("[markStuck] progress event failed (non-fatal): event down");
    expect(logFn).toHaveBeenCalledWith("[markStuck] fail event failed (non-fatal): event down");
  });
});
