/**
 * TRD-NF-001-TEST: Verify binary availability checks on startup.
 *
 * run.ts calls ensureBrInstalled() before dispatching.
 * bv absence is a warning (null return), not a blocking error.
 */

import { describe, it, expect, vi } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────

const { mockAccess } = vi.hoisted(() => ({
  mockAccess: vi.fn(),
}));

vi.mock("node:fs/promises", () => ({
  access: mockAccess,
}));

import { BeadsRustClient } from "../beads-rust.js";

// ── ensureBrInstalled ────────────────────────────────────────────────────────

describe("TRD-NF-001: BeadsRustClient.ensureBrInstalled()", () => {
  it("resolves when br binary exists", async () => {
    mockAccess.mockResolvedValue(undefined);
    const client = new BeadsRustClient("/tmp/project");
    await expect(client.ensureBrInstalled()).resolves.toBeUndefined();
  });

  it("throws with cargo install message when binary missing", async () => {
    mockAccess.mockRejectedValue(new Error("ENOENT"));
    const client = new BeadsRustClient("/tmp/project");
    await expect(client.ensureBrInstalled()).rejects.toThrow("cargo install beads_rust");
  });

  it("error message mentions the expected path", async () => {
    mockAccess.mockRejectedValue(new Error("ENOENT"));
    const client = new BeadsRustClient("/tmp/project");
    await expect(client.ensureBrInstalled()).rejects.toThrow("br (beads_rust) CLI not found");
  });
});
