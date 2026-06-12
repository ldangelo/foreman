import { describe, expect, it, vi } from "vitest";
import {
  closeStoreIfPossible,
  wrapLocalRunStore,
} from "../local-store-adapter.js";
import type { ForemanStore, Run } from "../../../lib/store.js";

function makeFakeStore() {
  const run = { id: "run-1", seed_id: "seed-1", status: "failed" } as unknown as Run;
  const project = { id: "proj-1", path: "/tmp/project" };

  const fake = {
    getProjectByPath: vi.fn().mockReturnValue(project),
    getRun: vi.fn().mockReturnValue(run),
    getActiveRuns: vi.fn().mockReturnValue([run]),
    getRunsByStatus: vi.fn().mockReturnValue([run]),
    getRunsForSeed: vi.fn().mockReturnValue([run]),
    updateRun: vi.fn(),
    deleteRun: vi.fn().mockReturnValue(true),
    logEvent: vi.fn(),
    close: vi.fn(),
    isOpen: vi.fn().mockReturnValue(true),
  };

  return { fake, store: fake as unknown as ForemanStore, run, project };
}

describe("wrapLocalRunStore", () => {
  it("delegates getProjectByPath and wraps the result in a promise", async () => {
    const { fake, store, project } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.getProjectByPath("/tmp/project")).resolves.toEqual(project);
    expect(fake.getProjectByPath).toHaveBeenCalledWith("/tmp/project");
  });

  it("delegates getRun", async () => {
    const { fake, store, run } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.getRun("run-1")).resolves.toEqual(run);
    expect(fake.getRun).toHaveBeenCalledWith("run-1");
  });

  it("delegates getActiveRuns", async () => {
    const { fake, store, run } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.getActiveRuns("proj-1")).resolves.toEqual([run]);
    expect(fake.getActiveRuns).toHaveBeenCalledWith("proj-1");
  });

  it("delegates getRunsByStatus", async () => {
    const { fake, store, run } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.getRunsByStatus("failed", "proj-1")).resolves.toEqual([run]);
    expect(fake.getRunsByStatus).toHaveBeenCalledWith("failed", "proj-1");
  });

  it("delegates getRunsForSeed", async () => {
    const { fake, store, run } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.getRunsForSeed("seed-1", "proj-1")).resolves.toEqual([run]);
    expect(fake.getRunsForSeed).toHaveBeenCalledWith("seed-1", "proj-1");
  });

  it("delegates updateRun", async () => {
    const { fake, store } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    const updates = { status: "reset" as Run["status"], completed_at: "2026-01-01T00:00:00.000Z" };
    await adapter.updateRun("run-1", updates);
    expect(fake.updateRun).toHaveBeenCalledWith("run-1", updates);
  });

  it("delegates deleteRun", async () => {
    const { fake, store } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await expect(adapter.deleteRun("run-1")).resolves.toBe(true);
    expect(fake.deleteRun).toHaveBeenCalledWith("run-1");
  });

  it("delegates logEvent with all arguments", async () => {
    const { fake, store } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    await adapter.logEvent("proj-1", "stuck", { reason: "test" }, "run-1");
    expect(fake.logEvent).toHaveBeenCalledWith("proj-1", "stuck", { reason: "test" }, "run-1");
  });

  it("exposes synchronous close and isOpen passthroughs", () => {
    const { fake, store } = makeFakeStore();
    const adapter = wrapLocalRunStore(store);

    expect(adapter.isOpen()).toBe(true);
    adapter.close();
    expect(fake.close).toHaveBeenCalledOnce();
  });
});

describe("closeStoreIfPossible", () => {
  it("calls close() when the store exposes it", () => {
    const close = vi.fn();
    closeStoreIfPossible({ close });
    expect(close).toHaveBeenCalledOnce();
  });

  it("ignores stores without a close method", () => {
    expect(() => closeStoreIfPossible({})).not.toThrow();
    expect(() => closeStoreIfPossible({ close: "not-a-function" })).not.toThrow();
  });

  it("ignores null and undefined", () => {
    expect(() => closeStoreIfPossible(null)).not.toThrow();
    expect(() => closeStoreIfPossible(undefined)).not.toThrow();
  });
});
