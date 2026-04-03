import { describe, it, expect, vi } from "vitest";
import type { ITaskClient } from "../../lib/task-client.js";

const {
  mockDetectDefaultBranch,
} = vi.hoisted(() => {
  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("dev");
  return { mockDetectDefaultBranch };
});

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "auto" }),
}));

import { resolveExplicitTargetBranch } from "../commands/run.js";

function makeTaskClient(labels?: string[]): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue([]),
    list: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({
      status: "open",
      description: null,
      notes: null,
      labels: labels ?? [],
    }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
  };
}

describe("resolveExplicitTargetBranch", () => {
  it("uses the detected default branch when no bead is specified", async () => {
    const taskClient = makeTaskClient();
    const vcs = {
      detectDefaultBranch: mockDetectDefaultBranch,
    } as never;

    const result = await resolveExplicitTargetBranch(taskClient, vcs, "/tmp");
    expect(result).toBe("dev");
  });

  it("uses the bead branch label when a single bead explicitly targets another branch", async () => {
    const taskClient = makeTaskClient(["branch:feature-x"]);
    const vcs = {
      detectDefaultBranch: mockDetectDefaultBranch,
    } as never;

    const result = await resolveExplicitTargetBranch(taskClient, vcs, "/tmp", "bd-1234");
    expect(result).toBe("feature-x");
  });

  it("falls back to default branch when bead labels are absent", async () => {
    const taskClient = makeTaskClient();
    const vcs = {
      detectDefaultBranch: mockDetectDefaultBranch,
    } as never;

    const result = await resolveExplicitTargetBranch(taskClient, vcs, "/tmp", "bd-1234");
    expect(result).toBe("dev");
  });
});
