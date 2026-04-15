import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockCreateTaskClient,
  sentinelTaskClient,
} = vi.hoisted(() => {
  const sentinelTaskClient = {
    list: vi.fn(),
    ready: vi.fn(),
    show: vi.fn(),
    update: vi.fn(),
    close: vi.fn(),
    create: vi.fn(),
  };

  const mockCreateTaskClient = vi.fn().mockResolvedValue({
    backendType: "beads",
    taskClient: sentinelTaskClient,
  });

  return {
    mockCreateTaskClient,
    sentinelTaskClient,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: (...args: unknown[]) => mockCreateTaskClient(...args),
}));

import { createSentinelTaskClient } from "../commands/sentinel.js";

describe("createSentinelTaskClient", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateTaskClient.mockResolvedValue({
      backendType: "beads",
      taskClient: sentinelTaskClient,
    });
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("uses the shared task-client helper and forces the compatibility fallback path", async () => {
    const taskClient = await createSentinelTaskClient("/mock/project");

    expect(mockCreateTaskClient).toHaveBeenCalledWith("/mock/project", {
      autoSelectNativeWhenAvailable: false,
    });
    expect(taskClient).toBe(sentinelTaskClient);
  });
});
