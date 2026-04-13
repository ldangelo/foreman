/**
 * Tests for TRD-021: Deprecate --sd-only flag in sling command.
 *
 * Verifies:
 * - --sd-only prints a deprecation warning to stderr
 * - legacy backend flags are cleared after applySdOnlyDeprecation() (native-only write)
 * - No warning is emitted when --sd-only is not set
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ─────────────────────────────────────────────────────────

const { mockStderrWrite } = vi.hoisted(() => {
  const mockStderrWrite = vi.fn();
  return { mockStderrWrite };
});

vi.mock("chalk", () => ({
  default: {
    yellow: (s: string) => s,
    dim: (s: string) => s,
    bold: (s: string) => s,
    green: (s: string) => s,
    red: (s: string) => s,
    cyan: (s: string) => s,
  },
}));

import { applySdOnlyDeprecation } from "../commands/sling.js";

// ── Tests ─────────────────────────────────────────────────────────────────

describe("TRD-021: applySdOnlyDeprecation()", () => {
  let originalStderrWrite: typeof process.stderr.write;

  beforeEach(() => {
    vi.clearAllMocks();
    originalStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = mockStderrWrite as unknown as typeof process.stderr.write;
  });

  afterEach(() => {
    process.stderr.write = originalStderrWrite;
  });

  it("returns false and emits no warning when sdOnly is false", () => {
    const opts = { sdOnly: false };
    const result = applySdOnlyDeprecation(opts);
    expect(result).toBe(false);
    expect(mockStderrWrite).not.toHaveBeenCalled();
  });

  it("returns false and emits no warning when sdOnly is undefined", () => {
    const opts: { sdOnly?: boolean } = {};
    const result = applySdOnlyDeprecation(opts);
    expect(result).toBe(false);
    expect(mockStderrWrite).not.toHaveBeenCalled();
  });

  it("returns true when sdOnly is true", () => {
    const opts = { sdOnly: true };
    const result = applySdOnlyDeprecation(opts);
    expect(result).toBe(true);
  });

  it("emits deprecation warning to stderr when sdOnly is true", () => {
    const opts = { sdOnly: true };
    applySdOnlyDeprecation(opts);
    expect(mockStderrWrite).toHaveBeenCalledOnce();
    const written = mockStderrWrite.mock.calls[0][0] as string;
    expect(written).toContain("SLING-DEPRECATED");
    expect(written).toContain("--sd-only");
    expect(written).toContain("deprecated");
  });

  it("warning message mentions the native task store", () => {
    const opts = { sdOnly: true };
    applySdOnlyDeprecation(opts);
    const written = mockStderrWrite.mock.calls[0][0] as string;
    expect(written).toContain("native task store");
    expect(written).toContain("Legacy backend flags are ignored");
  });

  it("clears sdOnly flag after emitting warning (no-op behavior)", () => {
    const opts = { sdOnly: true };
    applySdOnlyDeprecation(opts);
    expect(opts.sdOnly).toBe(false);
  });

  it("clears brOnly to keep native-only write semantics", () => {
    const opts: { sdOnly?: boolean; brOnly?: boolean } = { sdOnly: true, brOnly: true };
    applySdOnlyDeprecation(opts);
    expect(opts.brOnly).toBe(false);
  });

  it("does not emit warning twice on repeated calls", () => {
    const opts = { sdOnly: true };
    applySdOnlyDeprecation(opts); // first call: emits warning, clears flag
    applySdOnlyDeprecation(opts); // second call: flag is false, no warning
    expect(mockStderrWrite).toHaveBeenCalledOnce();
  });
});
