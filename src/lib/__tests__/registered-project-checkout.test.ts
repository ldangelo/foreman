import { describe, it, expect, vi, beforeEach } from "vitest";

const { mockExecFileSync, mockRmSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockRmSync: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("node:fs", () => ({
  rmSync: mockRmSync,
}));

import { syncRegisteredProjectCheckout } from "../registered-project-checkout.js";

function setGitResponses(responses: Record<string, string | Error>): void {
  mockExecFileSync.mockImplementation((cmd: string, args: string[]) => {
    expect(cmd).toBe("git");
    const key = args.join(" ");
    const response = responses[key];
    if (response instanceof Error) throw response;
    if (response !== undefined) return response;
    return "";
  });
}

describe("syncRegisteredProjectCheckout", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("restores controller-only dirt and fast-forwards the managed checkout", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "diff --name-only": ".beads/issues.jsonl\n",
      "diff --cached --name-only": "",
      "ls-files --others --exclude-standard": ".beads/last-touched\n",
      "symbolic-ref --quiet --short HEAD": "feature/local\n",
      "checkout main": "",
      "restore --source=HEAD --staged --worktree -- .beads/issues.jsonl": "",
      "reset --hard origin/main": "HEAD is now at 39eb3d7b\n",
    });

    syncRegisteredProjectCheckout({
      projectId: "foreman-b90e0",
      projectPath: "/repo",
      defaultBranch: "main",
    });

    expect(mockExecFileSync).toHaveBeenCalledWith("git", ["restore", "--source=HEAD", "--staged", "--worktree", "--", ".beads/issues.jsonl"], expect.objectContaining({ cwd: "/repo" }));
    expect(mockRmSync).toHaveBeenCalledWith("/repo/.beads/last-touched", { recursive: true, force: true });
    expect(mockExecFileSync).toHaveBeenCalledWith("git", ["checkout", "main"], expect.objectContaining({ cwd: "/repo" }));
    expect(mockExecFileSync).toHaveBeenCalledWith("git", ["reset", "--hard", "origin/main"], expect.objectContaining({ cwd: "/repo" }));
  });

  it("warns and skips fast-forward when non-controller changes exist", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "diff --name-only": "src/index.ts\n",
      "diff --cached --name-only": "",
      "ls-files --others --exclude-standard": "",
    });
    const warn = vi.fn();

    syncRegisteredProjectCheckout({
      projectId: "foreman-b90e0",
      projectPath: "/repo",
      defaultBranch: "main",
      warn,
    });

    expect(warn).toHaveBeenCalledWith(expect.stringContaining("src/index.ts"));
    expect(mockExecFileSync).not.toHaveBeenCalledWith("git", ["reset", "--hard", "origin/main"], expect.anything());
    expect(mockRmSync).not.toHaveBeenCalled();
  });
});
