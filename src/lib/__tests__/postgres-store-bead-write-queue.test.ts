import { beforeEach, describe, expect, it, vi } from "vitest";
import { PostgresStore } from "../postgres-store.js";
import type { PostgresAdapter } from "../db/postgres-adapter.js";

describe("PostgresStore bead write queue parity", () => {
  const enqueueBeadWrite = vi.fn().mockResolvedValue(undefined);
  const getPendingBeadWrites = vi.fn().mockResolvedValue([
    {
      id: "bw-1",
      sender: "refinery",
      operation: "close-seed",
      payload: JSON.stringify({ seedId: "bd-123" }),
      created_at: "2026-05-04T20:00:00.000Z",
      processed_at: null,
    },
  ]);
  const markBeadWriteProcessed = vi.fn().mockResolvedValue(true);

  const adapter = {
    enqueueBeadWrite,
    getPendingBeadWrites,
    markBeadWriteProcessed,
  } as unknown as PostgresAdapter;

  beforeEach(() => {
    enqueueBeadWrite.mockClear();
    getPendingBeadWrites.mockClear();
    markBeadWriteProcessed.mockClear();
  });

  it("delegates enqueueBeadWrite to the adapter with project scoping", async () => {
    const store = new PostgresStore("proj-123", adapter);

    await store.enqueueBeadWrite("refinery", "close-seed", { seedId: "bd-123" });

    expect(enqueueBeadWrite).toHaveBeenCalledWith("proj-123", "refinery", "close-seed", { seedId: "bd-123" });
  });

  it("returns pending bead writes from the adapter", async () => {
    const store = new PostgresStore("proj-123", adapter);

    await expect(store.getPendingBeadWrites()).resolves.toEqual([
      expect.objectContaining({
        id: "bw-1",
        sender: "refinery",
        operation: "close-seed",
        payload: JSON.stringify({ seedId: "bd-123" }),
        processed_at: null,
      }),
    ]);
    expect(getPendingBeadWrites).toHaveBeenCalledWith("proj-123");
  });

  it("marks bead writes processed through the adapter", async () => {
    const store = new PostgresStore("proj-123", adapter);

    await expect(store.markBeadWriteProcessed("bw-1")).resolves.toBe(true);
    expect(markBeadWriteProcessed).toHaveBeenCalledWith("proj-123", "bw-1");
  });
});
