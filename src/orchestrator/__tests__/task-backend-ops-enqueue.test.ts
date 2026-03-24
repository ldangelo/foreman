/**
 * Tests for the queue-based enqueue wrapper functions in task-backend-ops.ts.
 *
 * These functions route br write operations through the ForemanStore
 * bead_write_queue table instead of calling br directly, eliminating
 * concurrent SQLite lock contention.
 */

import { describe, it, expect } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import {
  enqueueCloseSeed,
  enqueueResetSeedToOpen,
  enqueueMarkBeadFailed,
  enqueueAddNotesToBead,
  enqueueAddLabelsToBead,
} from "../task-backend-ops.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeTmpStore(): { store: ForemanStore; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "enqueue-test-"));
  const store = ForemanStore.forProject(dir);
  return {
    store,
    cleanup: () => {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("enqueueCloseSeed()", () => {
  it("enqueues a close-seed operation in the store", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueCloseSeed(store, "bd-test", "refinery");
      const entries = store.getPendingBeadWrites();
      expect(entries).toHaveLength(1);
      expect(entries[0].operation).toBe("close-seed");
      expect(JSON.parse(entries[0].payload)).toEqual({ seedId: "bd-test" });
      expect(entries[0].sender).toBe("refinery");
    } finally {
      cleanup();
    }
  });

  it("does not throw when store fails (non-fatal)", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      store.close();
      // After close, enqueue should swallow the error
      expect(() => enqueueCloseSeed(store, "bd-abc", "sender")).not.toThrow();
    } finally {
      cleanup();
    }
  });
});

describe("enqueueResetSeedToOpen()", () => {
  it("enqueues a reset-seed operation", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueResetSeedToOpen(store, "bd-reset", "agent-worker");
      const entries = store.getPendingBeadWrites();
      expect(entries[0].operation).toBe("reset-seed");
      expect(JSON.parse(entries[0].payload).seedId).toBe("bd-reset");
      expect(entries[0].sender).toBe("agent-worker");
    } finally {
      cleanup();
    }
  });
});

describe("enqueueMarkBeadFailed()", () => {
  it("enqueues a mark-failed operation", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueMarkBeadFailed(store, "bd-fail", "auto-merge");
      const entries = store.getPendingBeadWrites();
      expect(entries[0].operation).toBe("mark-failed");
      expect(JSON.parse(entries[0].payload).seedId).toBe("bd-fail");
      expect(entries[0].sender).toBe("auto-merge");
    } finally {
      cleanup();
    }
  });
});

describe("enqueueAddNotesToBead()", () => {
  it("enqueues an add-notes operation with the note text", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddNotesToBead(store, "bd-notes", "Some failure reason", "agent-worker");
      const entries = store.getPendingBeadWrites();
      expect(entries[0].operation).toBe("add-notes");
      const payload = JSON.parse(entries[0].payload);
      expect(payload.seedId).toBe("bd-notes");
      expect(payload.notes).toBe("Some failure reason");
    } finally {
      cleanup();
    }
  });

  it("does nothing when notes is empty string", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddNotesToBead(store, "bd-empty", "", "sender");
      expect(store.getPendingBeadWrites()).toHaveLength(0);
    } finally {
      cleanup();
    }
  });

  it("truncates notes longer than 2000 characters", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      const longNote = "x".repeat(3000);
      enqueueAddNotesToBead(store, "bd-long", longNote, "sender");
      const payload = JSON.parse(store.getPendingBeadWrites()[0].payload);
      // 2000 chars + "…" = 2001 chars max
      expect(payload.notes.length).toBeLessThanOrEqual(2001);
      expect(payload.notes).toContain("…");
    } finally {
      cleanup();
    }
  });

  it("does not enqueue when notes is whitespace (empty-like)", () => {
    // Note: Only truly empty string is suppressed; whitespace passes through
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddNotesToBead(store, "bd-ws", "   ", "sender");
      // Non-empty string (whitespace) is NOT suppressed
      expect(store.getPendingBeadWrites()).toHaveLength(1);
    } finally {
      cleanup();
    }
  });
});

describe("enqueueAddLabelsToBead()", () => {
  it("enqueues an add-labels operation with all labels", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddLabelsToBead(store, "bd-labels", ["phase:dev", "ci:pass"], "pipeline-executor");
      const entries = store.getPendingBeadWrites();
      expect(entries[0].operation).toBe("add-labels");
      const payload = JSON.parse(entries[0].payload);
      expect(payload.seedId).toBe("bd-labels");
      expect(payload.labels).toEqual(["phase:dev", "ci:pass"]);
      expect(entries[0].sender).toBe("pipeline-executor");
    } finally {
      cleanup();
    }
  });

  it("does nothing when labels array is empty", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddLabelsToBead(store, "bd-nolabels", [], "sender");
      expect(store.getPendingBeadWrites()).toHaveLength(0);
    } finally {
      cleanup();
    }
  });

  it("enqueues single label", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueAddLabelsToBead(store, "bd-single", ["phase:qa"], "pipeline-executor");
      const payload = JSON.parse(store.getPendingBeadWrites()[0].payload);
      expect(payload.labels).toEqual(["phase:qa"]);
    } finally {
      cleanup();
    }
  });
});

describe("queue write ordering", () => {
  it("multiple enqueues produce entries in insertion order", () => {
    const { store, cleanup } = makeTmpStore();
    try {
      enqueueCloseSeed(store, "bd-1", "refinery");
      enqueueResetSeedToOpen(store, "bd-2", "agent-worker");
      enqueueMarkBeadFailed(store, "bd-3", "auto-merge");

      const entries = store.getPendingBeadWrites();
      expect(entries).toHaveLength(3);
      expect(entries[0].operation).toBe("close-seed");
      expect(entries[1].operation).toBe("reset-seed");
      expect(entries[2].operation).toBe("mark-failed");
    } finally {
      cleanup();
    }
  });
});
