import { describe, expect, it } from "vitest";
import { getTaskRetryTargetStatus } from "../run-status.js";

const RETRYABLE_STATUSES = [
  "backlog",
  "ready",
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

describe("getTaskRetryTargetStatus", () => {
  it.each(TERMINAL_STATUSES)("keeps terminal status %s unchanged", (status) => {
    expect(getTaskRetryTargetStatus(status, { command: "reset" })).toBeNull();
    expect(getTaskRetryTargetStatus(status, { command: "retry", backendType: "native" })).toBeNull();
  });

  it.each(RETRYABLE_STATUSES)("resets retryable status %s to ready", (status) => {
    expect(getTaskRetryTargetStatus(status, { command: "reset" })).toBe("ready");
    expect(getTaskRetryTargetStatus(status, { command: "retry", backendType: "native" })).toBe("ready");
  });

  it("leaves unknown statuses unchanged", () => {
    expect(getTaskRetryTargetStatus("open", { command: "reset" })).toBeNull();
    expect(getTaskRetryTargetStatus("in_progress", { command: "retry", backendType: "native" })).toBeNull();
  });
});
