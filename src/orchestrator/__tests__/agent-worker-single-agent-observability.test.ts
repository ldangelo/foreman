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
  it("does not route single-agent writes through database stores", () => {
    const source = readFileSync(WORKER_SRC, "utf8");

    expect(source).toContain("createWorkerStoreCompat()");
    expect(source).toContain("writeSingleAgentProgress(undefined, runId, progress, log)");
    expect(source).not.toContain("ForemanStore.forProject");
    expect(source).not.toContain("localStore");
    expect(source).not.toContain("registeredReadStore.updateRunProgress");
  });

  it("emits through provided writer when present", async () => {
    const writer = { updateProgress: vi.fn(), logEvent: vi.fn() };
    const logFn = vi.fn();

    await writeSingleAgentProgress(writer, "run-1", progress, logFn);
    await writeSingleAgentTerminalEvent(writer, "proj-1", "run-1", "complete", { taskId: "task-1" }, logFn);

    expect(writer.updateProgress).toHaveBeenCalledWith(progress);
    expect(writer.logEvent).toHaveBeenCalledWith("complete", { taskId: "task-1" });
    expect(logFn).not.toHaveBeenCalled();
  });

  it("does nothing when no writer is provided", async () => {
    const logFn = vi.fn();

    await writeSingleAgentProgress(undefined, "run-1", progress, logFn);
    await writeSingleAgentTerminalEvent(undefined, "proj-1", "run-1", "fail", { reason: "boom" }, logFn);

    expect(logFn).not.toHaveBeenCalled();
  });
});
