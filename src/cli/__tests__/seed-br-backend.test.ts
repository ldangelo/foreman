/**
 * Tests for TRD-015: Backend selection in seed.ts based on FOREMAN_TASK_BACKEND.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': BeadsRustClient is used for issue creation
 * - Priority input is normalized correctly via normalizePriority()
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks (vi.mock factories are hoisted; vars must use vi.hoisted) ──
const {
  mockGetTaskBackend,
  MockBeadsRustClient,
  mockBrCreate,
  mockBrEnsureInstalled,
  mockBrIsInitialized,
  mockBrAddDependency,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("br");

  const mockBrCreate = vi.fn().mockResolvedValue({ id: "br-001", title: "Test Issue" });
  const mockBrEnsureInstalled = vi.fn().mockResolvedValue(undefined);
  const mockBrIsInitialized = vi.fn().mockResolvedValue(true);
  const mockBrAddDependency = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.create = mockBrCreate;
    this.ensureBrInstalled = mockBrEnsureInstalled;
    this.isInitialized = mockBrIsInitialized;
    this.addDependency = mockBrAddDependency;
  });

  return {
    mockGetTaskBackend,
    MockBeadsRustClient,
    mockBrCreate,
    mockBrEnsureInstalled,
    mockBrIsInitialized,
    mockBrAddDependency,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

// ── Module under test ──────────────────────────────────────────────────────
// We import seedCommand to verify it loads without error; actual logic tested
// by calling the action handler directly via the exported factory helpers.
// We test the backend selection by calling createSeedClient (exported for testing).
import { createSeedClient } from "../commands/seed.js";

// ── Helpers ────────────────────────────────────────────────────────────────

const PROJECT_PATH = "/mock/project";

describe("TRD-015: seed.ts backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.create = mockBrCreate;
      this.ensureBrInstalled = mockBrEnsureInstalled;
      this.isInitialized = mockBrIsInitialized;
      this.addDependency = mockBrAddDependency;
    });
    mockBrCreate.mockResolvedValue({ id: "br-001", title: "Test Issue" });
    mockBrEnsureInstalled.mockResolvedValue(undefined);
    mockBrIsInitialized.mockResolvedValue(true);
    mockBrAddDependency.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── br backend ──────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("returns a BeadsRustClient instance", () => {
      const client = createSeedClient(PROJECT_PATH);

      expect(MockBeadsRustClient).toHaveBeenCalledWith(PROJECT_PATH);
      expect(MockBeadsRustClient).toHaveBeenCalledTimes(1);
      expect(client).toBeDefined();
    });

    it("returned client has a create method (BeadsRustClient API)", () => {
      const client = createSeedClient(PROJECT_PATH);

      // The BeadsRustClient mock exposes 'create'
      expect(typeof (client as unknown as Record<string, unknown>).create).toBe("function");
    });
  });

});

// ── Priority normalization tests ────────────────────────────────────────────

describe("TRD-015: seed.ts priority normalization", () => {
  it("normalizePriority accepts P0-P4 notation", async () => {
    const { normalizePriority } = await import("../../lib/priority.js");

    expect(normalizePriority("P0")).toBe(0);
    expect(normalizePriority("P1")).toBe(1);
    expect(normalizePriority("P2")).toBe(2);
    expect(normalizePriority("P3")).toBe(3);
    expect(normalizePriority("P4")).toBe(4);
  });

  it("normalizePriority accepts numeric string notation", async () => {
    const { normalizePriority } = await import("../../lib/priority.js");

    expect(normalizePriority("0")).toBe(0);
    expect(normalizePriority("2")).toBe(2);
    expect(normalizePriority("4")).toBe(4);
  });

  it("normalizePriority defaults to 4 for invalid input", async () => {
    const { normalizePriority } = await import("../../lib/priority.js");

    expect(normalizePriority("high")).toBe(4);
    expect(normalizePriority("critical")).toBe(4);
    expect(normalizePriority("")).toBe(4);
  });

  it("normalizePriority accepts numeric values", async () => {
    const { normalizePriority } = await import("../../lib/priority.js");

    expect(normalizePriority(0)).toBe(0);
    expect(normalizePriority(2)).toBe(2);
    expect(normalizePriority(4)).toBe(4);
  });

  it("normalizePriority is case-insensitive for P-notation", async () => {
    const { normalizePriority } = await import("../../lib/priority.js");

    expect(normalizePriority("p0")).toBe(0);
    expect(normalizePriority("p2")).toBe(2);
    expect(normalizePriority("P4")).toBe(4);
  });
});
