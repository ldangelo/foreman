import { describe, expect, it, vi } from "vitest";
import { PostgresStore } from "../postgres-store.js";
import type { PostgresAdapter } from "../db/postgres-adapter.js";

describe("PostgresStore rate-limit telemetry", () => {
  it("accepts the worker logRateLimitEvent call shape", async () => {
    const logRateLimitEvent = vi.fn().mockResolvedValue(undefined);
    const adapter = { logRateLimitEvent } as unknown as PostgresAdapter;
    const store = new PostgresStore("proj-123", adapter);

    await store.logRateLimitEvent(
      "proj-123",
      "claude-sonnet-4-6",
      "developer",
      "rate limit hit",
      30,
      "run-456",
    );

    expect(logRateLimitEvent).toHaveBeenCalledWith(
      "proj-123",
      "run-456",
      "claude-sonnet-4-6",
      "developer",
      "rate limit hit",
      30,
    );
  });
});
