import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import type { RunProgress } from "../../lib/store.js";
import { writeSingleAgentProgress, writeSingleAgentTerminalEvent } from "../agent-worker-single-agent-observability.js";

const WORKER_SRC = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));

const progress: RunProgress = {
  toolCalls: 4,
  toolBreakdown: {},
  filesChanged: [],
  turns: 9,
  costUsd: 2.5,
  tokensIn: 25,
  tokensOut: 50,
  lastToolCall: null,
  lastActivity: new Date().toISOString(),
};

describe("single-agent observability routing", () => {
  it("serializes single-agent progress flushes without fire-and-forget writes", () => {
    const source = readFileSync(WORKER_SRC, "utf8");

    expect(source).not.toContain("void writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log);");

    const tailIndex = source.indexOf("progressFlushTail = progressFlushTail.then(() => writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log));");
    const dirtyIndex = source.indexOf("progressDirty = false;");

    expect(tailIndex).toBeGreaterThan(-1);
    expect(dirtyIndex).toBeGreaterThan(-1);
    expect(tailIndex).toBeGreaterThan(dirtyIndex);
  });

  it("waits for any in-flight flush before the final single-agent snapshot write", () => {
    const source = readFileSync(WORKER_SRC, "utf8");

    const waitIndex = source.indexOf("await waitForProgressFlush();");
    const tokensInIndex = source.indexOf("progress.tokensIn = piResult.tokensIn;");
    const tokensOutIndex = source.indexOf("progress.tokensOut = piResult.tokensOut;");
    const flushIndex = source.indexOf("await writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log);");

    expect(waitIndex).toBeGreaterThan(-1);
    expect(tokensInIndex).toBeGreaterThan(-1);
    expect(tokensOutIndex).toBeGreaterThan(tokensInIndex);
    expect(flushIndex).toBeGreaterThan(tokensOutIndex);
    expect(flushIndex).toBeGreaterThan(waitIndex);
  });

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

    await writeSingleAgentProgress(localStore as never, registeredStore as never, "run-1", progress, logFn);
    await writeSingleAgentTerminalEvent(
      localStore as never,
      registeredStore as never,
      "proj-1",
      "run-1",
      "complete",
      { seedId: "seed-1", title: "Seed 1" },
      logFn,
    );

    expect(registeredStore.updateRunProgress).toHaveBeenCalledWith("run-1", progress);
    expect(registeredStore.logEvent).toHaveBeenCalledWith("proj-1", "complete", { seedId: "seed-1", title: "Seed 1" }, "run-1");
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

    await writeSingleAgentProgress(localStore as never, registeredStore as never, "run-2", progress, logFn);
    await writeSingleAgentTerminalEvent(
      localStore as never,
      registeredStore as never,
      "proj-2",
      "run-2",
      "fail",
      { seedId: "seed-2", reason: "boom" },
      logFn,
    );

    expect(localStore.updateRunProgress).toHaveBeenCalledWith("run-2", progress);
    expect(localStore.logEvent).toHaveBeenCalledWith("proj-2", "fail", { seedId: "seed-2", reason: "boom" }, "run-2");
    expect(localStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(localStore.logEvent).toHaveBeenCalledTimes(1);
    expect(registeredStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(registeredStore.logEvent).toHaveBeenCalledTimes(1);
    expect(logFn).toHaveBeenCalledWith("[agent-worker] registered single-agent progress write failed (non-fatal); falling back to local store: pg down");
    expect(logFn).toHaveBeenCalledWith("[agent-worker] registered single-agent terminal event write failed (non-fatal); falling back to local store: pg down");
  });

  it("keeps local/unregistered behavior unchanged", async () => {
    const localStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const logFn = vi.fn();

    await writeSingleAgentProgress(localStore as never, undefined, "run-3", progress, logFn);
    await writeSingleAgentTerminalEvent(
      localStore as never,
      undefined,
      "proj-3",
      "run-3",
      "stuck",
      { seedId: "seed-3", reason: "rate limit" },
      logFn,
    );

    expect(localStore.updateRunProgress).toHaveBeenCalledWith("run-3", progress);
    expect(localStore.logEvent).toHaveBeenCalledWith("proj-3", "stuck", { seedId: "seed-3", reason: "rate limit" }, "run-3");
    expect(localStore.updateRunProgress).toHaveBeenCalledTimes(1);
    expect(localStore.logEvent).toHaveBeenCalledTimes(1);
    expect(logFn).not.toHaveBeenCalled();
  });
});
