/**
 * Tests for src/orchestrator/pipeline-events.ts
 *
 * Verifies:
 * - TRD-001-TEST: PipelineEventBus — typed emit/on/safeEmit
 *   - All 9 PipelineEvent variants can be emitted and received
 *   - Handlers receive the full event object with correct types
 *   - safeEmit catches synchronously throwing handlers -> pipeline:error
 *   - safeEmit catches async handler rejections -> pipeline:error
 *   - off() removes a handler
 *   - removeAllListeners() clears all handlers
 */

import { describe, it, expect, vi } from "vitest";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent, PipelineEventOf } from "../pipeline-events.js";

describe("PipelineEventBus", () => {
  // ── emit / on ───────────────────────────────────────────────────────────────

  it("AC-T-001-1: registered phase:complete handler receives full event object", () => {
    const bus = new PipelineEventBus();
    const received: PipelineEventOf<"phase:complete">[] = [];

    bus.on("phase:complete", (e) => { received.push(e); });

    const event: PipelineEvent = {
      type: "phase:complete",
      runId: "run-1",
      phase: "developer",
      worktreePath: "/tmp/wt",
      cost: 0.05,
    };
    bus.emit(event);

    expect(received).toHaveLength(1);
    expect(received[0]).toEqual(event);
  });

  it("all 9 PipelineEvent variants can be emitted and received via on()", () => {
    const bus = new PipelineEventBus();

    const events: PipelineEvent[] = [
      { type: "phase:start",       runId: "r", phase: "explorer", worktreePath: "/wt" },
      { type: "phase:complete",    runId: "r", phase: "developer", worktreePath: "/wt", cost: 0 },
      { type: "phase:fail",        runId: "r", phase: "qa", error: "fail", retryable: true },
      { type: "rebase:start",      runId: "r", phase: "developer", target: "origin/dev" },
      { type: "rebase:clean",      runId: "r", phase: "developer", upstreamCommits: 2, changedFiles: ["a.ts"] },
      { type: "rebase:conflict",   runId: "r", phase: "developer", conflictingFiles: ["src/x.ts"] },
      { type: "rebase:resolved",   runId: "r", resumePhase: "developer" },
      { type: "pipeline:complete", runId: "r", status: "completed" },
      { type: "pipeline:fail",     runId: "r", error: "fatal" },
    ];

    const received: PipelineEvent[] = [];
    for (const event of events) {
      bus.on(event.type, (e) => { received.push(e as PipelineEvent); });
    }

    for (const event of events) {
      bus.emit(event);
    }

    expect(received).toHaveLength(9);
    for (let i = 0; i < events.length; i++) {
      expect(received[i]).toEqual(events[i]);
    }
  });

  it("off() removes a previously registered handler", () => {
    const bus = new PipelineEventBus();
    const calls: number[] = [];
    const handler = (e: PipelineEventOf<"phase:start">) => {
      calls.push(1);
      void e;
    };

    bus.on("phase:start", handler);
    bus.emit({ type: "phase:start", runId: "r", phase: "explorer", worktreePath: "/wt" });
    expect(calls).toHaveLength(1);

    bus.off("phase:start", handler);
    bus.emit({ type: "phase:start", runId: "r", phase: "explorer", worktreePath: "/wt" });
    expect(calls).toHaveLength(1); // no new calls
  });

  it("removeAllListeners() clears all registered handlers", () => {
    const bus = new PipelineEventBus();
    const calls: number[] = [];

    bus.on("phase:start", () => { calls.push(1); });
    bus.on("phase:complete", () => { calls.push(2); });
    bus.removeAllListeners();

    bus.emit({ type: "phase:start", runId: "r", phase: "explorer", worktreePath: "/wt" });
    bus.emit({ type: "phase:complete", runId: "r", phase: "developer", worktreePath: "/wt", cost: 0 });

    expect(calls).toHaveLength(0);
  });

  // ── safeEmit — synchronous handler errors ───────────────────────────────────

  it("AC-T-001-2: safeEmit — synchronously throwing handler emits pipeline:error, does not rethrow", () => {
    const bus = new PipelineEventBus();
    const errors: PipelineEventOf<"pipeline:error">[] = [];

    bus.on("pipeline:error", (e) => { errors.push(e); });
    bus.on("phase:complete", () => {
      throw new Error("handler boom");
    });

    // Must not throw
    expect(() => {
      bus.safeEmit({
        type: "phase:complete",
        runId: "run-1",
        phase: "developer",
        worktreePath: "/wt",
        cost: 0.1,
      });
    }).not.toThrow();

    expect(errors).toHaveLength(1);
    expect(errors[0].type).toBe("pipeline:error");
    expect(errors[0].error).toContain("handler boom");
    expect(errors[0].originalEvent).toBe("phase:complete");
    expect(errors[0].runId).toBe("run-1");
  });

  it("AC-T-001-3: safeEmit — async handler rejection emits pipeline:error (not unhandled rejection)", async () => {
    const bus = new PipelineEventBus();
    const errors: PipelineEventOf<"pipeline:error">[] = [];

    bus.on("pipeline:error", (e) => { errors.push(e); });
    bus.on("phase:complete", async () => {
      throw new Error("async boom");
    });

    bus.safeEmit({
      type: "phase:complete",
      runId: "run-async",
      phase: "qa",
      worktreePath: "/wt",
      cost: 0,
    });

    // Allow microtask queue to flush
    await new Promise((resolve) => setImmediate(resolve));

    expect(errors).toHaveLength(1);
    expect(errors[0].error).toContain("async boom");
    expect(errors[0].runId).toBe("run-async");
  });

  it("safeEmit — multiple handlers: one throws, others still execute", () => {
    const bus = new PipelineEventBus();
    const executed: string[] = [];
    const errors: string[] = [];

    bus.on("pipeline:error", (e) => { errors.push(e.error); });
    bus.on("phase:start", () => { executed.push("handler-1"); });
    bus.on("phase:start", () => { throw new Error("middle crash"); });
    bus.on("phase:start", () => { executed.push("handler-3"); });

    bus.safeEmit({ type: "phase:start", runId: "r", phase: "explorer", worktreePath: "/wt" });

    expect(executed).toContain("handler-1");
    expect(executed).toContain("handler-3");
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("middle crash");
  });

  it("AC-T-001-4: TypeScript types narrow correctly per event variant (compilation test)", () => {
    const bus = new PipelineEventBus();

    // This test primarily validates at compile time — if these compile without error,
    // TypeScript correctly narrows the event type in each handler.
    bus.on("phase:complete", (e) => {
      // TypeScript should narrow e to PipelineEventOf<"phase:complete">
      const _cost: number = e.cost;
      const _phase: string = e.phase;
      void _cost; void _phase;
    });

    bus.on("rebase:conflict", (e) => {
      const _files: string[] = e.conflictingFiles;
      void _files;
    });

    bus.on("rebase:resolved", (e) => {
      const _resumePhase: string = e.resumePhase;
      void _resumePhase;
    });

    // Runtime: emit and verify handler actually fires
    const spy = vi.fn();
    bus.on("pipeline:complete", spy);
    bus.emit({ type: "pipeline:complete", runId: "r", status: "completed" });
    expect(spy).toHaveBeenCalledOnce();
  });
});
