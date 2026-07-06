import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockApproveDashboard, mockRetryDashboard } = vi.hoisted(() => ({
  mockApproveDashboard: vi.fn(),
  mockRetryDashboard: vi.fn(),
}));

vi.mock("../../../dashboard-state.js", () => ({
  approveTask: mockApproveDashboard,
  retryTask: mockRetryDashboard,
}));

import { approveTask, retryTask } from "../actions.js";

describe("watch actions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns true when approve succeeds", async () => {
    mockApproveDashboard.mockResolvedValue(undefined);

    await expect(approveTask("task-1", "/tmp/project")).resolves.toBe(true);
    expect(mockApproveDashboard).toHaveBeenCalledWith("task-1", "/tmp/project");
  });

  it("returns false when approve fails", async () => {
    mockApproveDashboard.mockRejectedValue(new Error("boom"));

    await expect(approveTask("task-1", "/tmp/project")).resolves.toBe(false);
  });

  it("returns true when retry succeeds", async () => {
    mockRetryDashboard.mockResolvedValue(undefined);

    await expect(retryTask("task-2", "/tmp/project")).resolves.toBe(true);
    expect(mockRetryDashboard).toHaveBeenCalledWith("task-2", "/tmp/project");
  });

  it("returns false when retry fails", async () => {
    mockRetryDashboard.mockRejectedValue(new Error("boom"));

    await expect(retryTask("task-2", "/tmp/project")).resolves.toBe(false);
  });
});
