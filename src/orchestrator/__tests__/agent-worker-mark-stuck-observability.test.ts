import { describe, expect, it, vi } from "vitest";
import type { RunProgress } from "../../lib/store.js";
import { writeMarkStuckEvent, writeMarkStuckProgress } from "../agent-worker-mark-stuck-observability.js";

const progress: RunProgress = {
  toolCalls: 3,
  toolBreakdown: {},
  filesChanged: [],
  turns: 7,
  costUsd: 1.23,
  tokensIn: 11,
  tokensOut: 22,
  lastToolCall: null,
  lastActivity: new Date().toISOString(),
  currentPhase: "developer",
};

describe("markStuck observability routing", () => {
  it("prefers registered Postgres writes and skips local fallback when registered writes succeed", async () => {
    const localStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const registeredStore = {
      updateRunProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const logFn = vi.fn();

    await writeMarkStuckProgress(localStore as never, registeredStore as never, "run-1", progress, logFn);
    await writeMarkStuckEvent(
      localStore as never,
      registeredStore as never,
      "proj-1",
      "run-1",
      "stuck",
      { seedId: "seed-1", phase: "developer" },
      logFn,
    );

    expect(registeredStore.updateRunProgress).toHaveBeenCalledWith("run-1", progress);
    expect(registeredStore.logEvent).toHaveBeenCalledWith("proj-1", "stuck", { seedId: "seed-1", phase: "developer" }, "run-1");
    expect(registeredStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(registeredStore.logEvent).toHaveBeenCalledTimes(1);
    expect(localStore.updateRunProgress).not.toHaveBeenCalled();
    expect(localStore.logEvent).not.toHaveBeenCalled();
    expect(logFn).not.toHaveBeenCalled();
  });

  it("falls back to local writes when registered Postgres writes fail", async () => {
    const localStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const registeredStore = {
      updateRunProgress: vi.fn().mockRejectedValue(new Error("pg down")),
      logEvent: vi.fn().mockRejectedValue(new Error("pg down")),
    };
    const logFn = vi.fn();

    await writeMarkStuckProgress(localStore as never, registeredStore as never, "run-2", progress, logFn);
    await writeMarkStuckEvent(
      localStore as never,
      registeredStore as never,
      "proj-2",
      "run-2",
      "fail",
      { seedId: "seed-2", phase: "qa" },
      logFn,
    );

    expect(localStore.updateRunProgress).toHaveBeenCalledWith("run-2", progress);
    expect(localStore.logEvent).toHaveBeenCalledWith("proj-2", "fail", { seedId: "seed-2", phase: "qa" }, "run-2");
    expect(localStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(localStore.logEvent).toHaveBeenCalledTimes(1);
    expect(registeredStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(registeredStore.logEvent).toHaveBeenCalledTimes(1);
    expect(logFn).toHaveBeenCalledWith("[markStuck] registered progress write failed (non-fatal); falling back to local store: pg down");
    expect(logFn).toHaveBeenCalledWith("[markStuck] registered fail event write failed (non-fatal); falling back to local store: pg down");
  });

  it("keeps local/unregistered behavior unchanged", async () => {
    const localStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const logFn = vi.fn();

    await writeMarkStuckProgress(localStore as never, undefined, "run-3", progress, logFn);
    await writeMarkStuckEvent(
      localStore as never,
      undefined,
      "proj-3",
      "run-3",
      "stuck",
      { seedId: "seed-3", phase: "review" },
      logFn,
    );

    expect(localStore.updateRunProgress).toHaveBeenCalledWith("run-3", progress);
    expect(localStore.logEvent).toHaveBeenCalledWith("proj-3", "stuck", { seedId: "seed-3", phase: "review" }, "run-3");
    expect(localStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(localStore.logEvent).toHaveBeenCalledTimes(1);
    expect(logFn).not.toHaveBeenCalled();
  });
});
