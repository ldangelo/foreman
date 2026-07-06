import { describe, expect, it } from "vitest";
import { getTaskRetryTargetStatus } from "../run-status.js";
import type { TaskClientBackend } from "../task-client-factory.js";

/**
 * Table-driven tests covering every status × mode combination that the two
 * original implementations handled:
 *
 *   - reset.ts  getResetTargetStatus(currentStatus)
 *   - retry.ts  getRetryTargetStatus(currentStatus, backendType)
 *
 * The shared function must preserve the exact behavior of both originals.
 */

const PIPELINE_STATUSES = [
  "backlog",
  "in-progress",
  "blocked",
  "conflict",
  "failed",
  "stuck",
  "explorer",
  "developer",
  "qa",
  "reviewer",
  "finalize",
] as const;

const TERMINAL_STATUSES = ["closed", "completed", "merged"] as const;

describe("getTaskRetryTargetStatus — reset semantics (foreman reset)", () => {
  const reset = (status: string) =>
    getTaskRetryTargetStatus(status, { command: "reset" });

  it('maps "open" → "open"', () => {
    expect(reset("open")).toBe("open");
  });

  it('maps "ready" → "ready"', () => {
    expect(reset("ready")).toBe("ready");
  });

  it.each(TERMINAL_STATUSES)('maps terminal status "%s" → null', (status) => {
    expect(reset(status)).toBeNull();
  });

  it.each(PIPELINE_STATUSES)(
    'maps retryable pipeline status "%s" → "ready"',
    (status) => {
      expect(reset(status)).toBe("ready");
    },
  );

  it('falls back to "open" for unknown / br-style statuses', () => {
    expect(reset("in_progress")).toBe("open");
    expect(reset("review")).toBe("open");
    expect(reset("something-else")).toBe("open");
  });
});

describe("getTaskRetryTargetStatus — retry semantics, native backend", () => {
  const retryNative = (status: string) =>
    getTaskRetryTargetStatus(status, { command: "retry", backendType: "native" });

  it.each(TERMINAL_STATUSES)('maps terminal status "%s" → null', (status) => {
    expect(retryNative(status)).toBeNull();
  });

  it('maps "ready" → "ready"', () => {
    expect(retryNative("ready")).toBe("ready");
  });

  it.each(PIPELINE_STATUSES)(
    'maps retryable pipeline status "%s" → "ready"',
    (status) => {
      expect(retryNative(status)).toBe("ready");
    },
  );

  it("falls back to null for unknown / br-style statuses", () => {
    expect(retryNative("open")).toBeNull();
    expect(retryNative("in_progress")).toBeNull();
    expect(retryNative("review")).toBeNull();
    expect(retryNative("something-else")).toBeNull();
  });
});

describe("getTaskRetryTargetStatus — retry semantics, br-style backend", () => {
  // TaskClientBackend currently only includes "native"; the br branch is kept
  // for behavioral parity with the original retry.ts implementation.
  const brBackend = "br" as unknown as TaskClientBackend;
  const retryBr = (status: string) =>
    getTaskRetryTargetStatus(status, { command: "retry", backendType: brBackend });

  it('maps "open" → "open"', () => {
    expect(retryBr("open")).toBe("open");
  });

  it.each(TERMINAL_STATUSES)('maps terminal status "%s" → null', (status) => {
    expect(retryBr(status)).toBeNull();
  });

  it('maps "in_progress" and "blocked" → "open"', () => {
    expect(retryBr("in_progress")).toBe("open");
    expect(retryBr("blocked")).toBe("open");
  });

  it("falls back to null for everything else (including native-style statuses)", () => {
    expect(retryBr("ready")).toBeNull();
    expect(retryBr("in-progress")).toBeNull();
    expect(retryBr("stuck")).toBeNull();
    expect(retryBr("review")).toBeNull();
  });
});
