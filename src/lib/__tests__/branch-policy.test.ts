import { describe, it, expect, vi } from "vitest";

const { mockLoadProjectConfig } = vi.hoisted(() => ({
  mockLoadProjectConfig: vi.fn(),
}));

vi.mock("../project-config.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../project-config.js")>();
  return {
    ...actual,
    loadProjectConfig: mockLoadProjectConfig,
  };
});

import { resolveProjectBranchPolicy } from "../branch-policy.js";
import type { ProjectConfig } from "../project-config.js";

function makeVcs(defaultBranch: string = "main") {
  return {
    detectDefaultBranch: vi.fn().mockResolvedValue(defaultBranch),
  };
}

describe("resolveProjectBranchPolicy", () => {
  it("falls back to the detected default branch for both branches", async () => {
    mockLoadProjectConfig.mockReturnValue(null);
    const vcs = makeVcs("main");

    await expect(resolveProjectBranchPolicy("/repo", vcs as never)).resolves.toEqual({
      defaultBranch: "main",
      integrationBranch: "main",
      requireValidation: false,
      autoPromote: false,
    });
    expect(vcs.detectDefaultBranch).toHaveBeenCalledWith("/repo");
  });

  it("honors explicit branch policy config", async () => {
    mockLoadProjectConfig.mockReturnValue({
      branchPolicy: {
        defaultBranch: "main",
        integrationBranch: "develop",
        requireValidation: true,
        autoPromote: true,
      },
    } satisfies ProjectConfig);

    await expect(resolveProjectBranchPolicy("/repo", makeVcs() as never)).resolves.toEqual({
      defaultBranch: "main",
      integrationBranch: "develop",
      requireValidation: true,
      autoPromote: true,
    });
  });

  it("uses configured integration branch while still detecting default branch when needed", async () => {
    mockLoadProjectConfig.mockReturnValue({
      branchPolicy: {
        integrationBranch: "dev",
      },
    } satisfies ProjectConfig);
    const vcs = makeVcs("main");

    await expect(resolveProjectBranchPolicy("/repo", vcs as never)).resolves.toEqual({
      defaultBranch: "main",
      integrationBranch: "dev",
      requireValidation: true,
      autoPromote: false,
    });
    expect(vcs.detectDefaultBranch).toHaveBeenCalledWith("/repo");
  });
});
