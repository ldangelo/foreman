import { describe, expect, it, vi } from "vitest";
import { createDualWriteStore } from "../rate-limit-dual-write.js";

describe("createDualWriteStore rate-limit logging", () => {
  it("prefers Postgres and skips local fallback when registered Postgres succeeds", async () => {
    const localStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn(),
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      logRateLimitEvent: vi.fn().mockResolvedValue(undefined),
    };
    const pgStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn().mockResolvedValue(undefined),
      updateRunProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
      logRateLimitEvent: vi.fn().mockResolvedValue(undefined),
    };
    const logFn = vi.fn();

    const store = createDualWriteStore(localStore as never, pgStore as never, true, logFn);

    await store.logRateLimitEvent("proj-1", "model-a", "developer", "rate limit hit", 30, "run-1");

    expect(pgStore.logRateLimitEvent).toHaveBeenCalledWith(
      "proj-1",
      "model-a",
      "developer",
      "rate limit hit",
      30,
      "run-1",
    );
    expect(localStore.logRateLimitEvent).not.toHaveBeenCalled();
    expect(logFn).not.toHaveBeenCalled();
  });

  it("falls back to local logging when registered Postgres write fails", async () => {
    const localStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn(),
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      logRateLimitEvent: vi.fn(),
    };
    const pgStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn().mockResolvedValue(undefined),
      updateRunProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
      logRateLimitEvent: vi.fn().mockRejectedValue(new Error("pg down")),
    };
    const logFn = vi.fn();

    const store = createDualWriteStore(localStore as never, pgStore as never, true, logFn);

    await store.logRateLimitEvent("proj-1", "model-a", "developer", "rate limit hit", 30, "run-1");

    expect(pgStore.logRateLimitEvent).toHaveBeenCalledTimes(1);
    expect(localStore.logRateLimitEvent).toHaveBeenCalledWith(
      "proj-1",
      "model-a",
      "developer",
      "rate limit hit",
      30,
      "run-1",
    );
    expect(logFn).toHaveBeenCalledWith("[postgres-mirror] logRateLimitEvent failed (non-fatal): pg down");
  });

  it("keeps unregistered behavior on the local store", async () => {
    const localStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn(),
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      logRateLimitEvent: vi.fn(),
    };
    const pgStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn().mockResolvedValue(undefined),
      updateRunProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
      logRateLimitEvent: vi.fn().mockResolvedValue(undefined),
    };

    const store = createDualWriteStore(localStore as never, pgStore as never, false);

    await store.logRateLimitEvent("proj-1", "model-a", "developer", "rate limit hit", 30, "run-1");

    expect(localStore.logRateLimitEvent).toHaveBeenCalledTimes(1);
    expect(pgStore.logRateLimitEvent).not.toHaveBeenCalled();
  });

  it("does not return the Postgres mirror promise from updateRunProgress", () => {
    const localStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn(),
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      logRateLimitEvent: vi.fn(),
    };
    const pgStore = {
      close: vi.fn(),
      sendMessage: vi.fn(),
      updateRun: vi.fn().mockResolvedValue(undefined),
      updateRunProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
      logRateLimitEvent: vi.fn().mockResolvedValue(undefined),
    };

    const store = createDualWriteStore(localStore as never, pgStore as never);
    const progress = {
      toolCalls: 1,
      toolBreakdown: { Edit: 1 },
      filesChanged: ["src/orchestrator/rate-limit-dual-write.ts"],
      turns: 1,
      costUsd: 0,
      tokensIn: 0,
      tokensOut: 0,
      lastToolCall: null,
      lastActivity: "2026-04-26T00:00:00.000Z",
    };

    const result = store.updateRunProgress("run-1", progress);

    expect(result).toBeUndefined();
    expect(localStore.updateRunProgress).toHaveBeenCalledWith("run-1", progress);
    expect(pgStore.updateRunProgress).toHaveBeenCalledTimes(1);
  });
});
