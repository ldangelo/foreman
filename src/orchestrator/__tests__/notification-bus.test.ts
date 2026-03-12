import { describe, it, expect, vi, beforeEach } from "vitest";
import { NotificationBus } from "../notification-bus.js";
import type { WorkerNotification } from "../types.js";

describe("NotificationBus", () => {
  let bus: NotificationBus;

  beforeEach(() => {
    bus = new NotificationBus();
  });

  it("emits 'notification' event when notify() is called", () => {
    const handler = vi.fn();
    bus.onNotification(handler);

    const n: WorkerNotification = {
      type: "status",
      runId: "run-123",
      status: "completed",
      timestamp: new Date().toISOString(),
    };
    bus.notify(n);

    expect(handler).toHaveBeenCalledOnce();
    expect(handler).toHaveBeenCalledWith(n);
  });

  it("emits per-run channel 'notification:<runId>'", () => {
    const handler = vi.fn();
    const runId = "run-abc";
    bus.onRunNotification(runId, handler);

    const n: WorkerNotification = {
      type: "status",
      runId,
      status: "running",
      timestamp: new Date().toISOString(),
    };
    bus.notify(n);

    expect(handler).toHaveBeenCalledOnce();
    expect(handler).toHaveBeenCalledWith(n);
  });

  it("does NOT invoke per-run handler for a different runId", () => {
    const handler = vi.fn();
    bus.onRunNotification("run-other", handler);

    const n: WorkerNotification = {
      type: "status",
      runId: "run-different",
      status: "failed",
      timestamp: new Date().toISOString(),
    };
    bus.notify(n);

    expect(handler).not.toHaveBeenCalled();
  });

  it("offRunNotification removes the listener", () => {
    const handler = vi.fn();
    const runId = "run-xyz";

    bus.onRunNotification(runId, handler);
    bus.offRunNotification(runId, handler);

    bus.notify({ type: "status", runId, status: "completed", timestamp: new Date().toISOString() });

    expect(handler).not.toHaveBeenCalled();
  });

  it("broadcasts progress notification on both channels", () => {
    const globalHandler = vi.fn();
    const runHandler = vi.fn();
    const runId = "run-prog";

    bus.onNotification(globalHandler);
    bus.onRunNotification(runId, runHandler);

    const n: WorkerNotification = {
      type: "progress",
      runId,
      progress: {
        toolCalls: 5,
        toolBreakdown: { Read: 3, Edit: 2 },
        filesChanged: ["src/foo.ts"],
        turns: 2,
        costUsd: 0.01,
        tokensIn: 1000,
        tokensOut: 200,
        lastToolCall: "Edit",
        lastActivity: new Date().toISOString(),
      },
      timestamp: new Date().toISOString(),
    };
    bus.notify(n);

    expect(globalHandler).toHaveBeenCalledWith(n);
    expect(runHandler).toHaveBeenCalledWith(n);
  });

  it("supports multiple listeners on the same run", () => {
    const handler1 = vi.fn();
    const handler2 = vi.fn();
    const runId = "run-multi";

    bus.onRunNotification(runId, handler1);
    bus.onRunNotification(runId, handler2);

    bus.notify({ type: "status", runId, status: "completed", timestamp: new Date().toISOString() });

    expect(handler1).toHaveBeenCalledOnce();
    expect(handler2).toHaveBeenCalledOnce();
  });

  it("singleton notificationBus is a NotificationBus instance", async () => {
    const { notificationBus } = await import("../notification-bus.js");
    expect(notificationBus).toBeInstanceOf(NotificationBus);
  });
});
