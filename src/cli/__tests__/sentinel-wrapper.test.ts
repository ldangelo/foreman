import { describe, expect, it, vi } from "vitest";

import { wrapPostgresSentinelStore } from "../commands/sentinel.js";

describe("wrapPostgresSentinelStore", () => {
  it("forwards recordSentinelEvent only when runId is present", async () => {
    const store = {
      close: vi.fn(),
      isOpen: vi.fn(() => true),
      recordSentinelEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    } as any;

    const wrapped = wrapPostgresSentinelStore(store, "proj-1");

    await wrapped.logEvent("ignored-project", "sentinel-pass", { runId: "run-1", foo: true });
    await wrapped.logEvent("ignored-project", "sentinel-fail", { foo: true });

    expect(store.recordSentinelEvent).toHaveBeenCalledTimes(1);
    expect(store.recordSentinelEvent).toHaveBeenCalledWith("ignored-project", "run-1", "sentinel-pass", { runId: "run-1", foo: true });
  });

  it("pins project-scoped calls to the wrapped project id", async () => {
    const store = {
      close: vi.fn(),
      isOpen: vi.fn(() => true),
      recordSentinelEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ enabled: 1 }),
      getSentinelRuns: vi.fn().mockResolvedValue([{ id: "run-1" }]),
    } as any;

    const wrapped = wrapPostgresSentinelStore(store, "proj-1");

    await wrapped.recordSentinelRun({ id: "run-1" } as any);
    await wrapped.upsertSentinelConfig("ignored-project", { enabled: 0 } as any);
    await wrapped.getSentinelConfig("ignored-project");
    await wrapped.getSentinelRuns("ignored-project", 5);

    expect(store.recordSentinelRun).toHaveBeenCalledWith("proj-1", { id: "run-1" });
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-1", { enabled: 0 });
    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-1");
    expect(store.getSentinelRuns).toHaveBeenCalledWith("proj-1", 5);
  });
});
