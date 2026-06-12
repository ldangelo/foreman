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

import {
  syncRegisteredProjectCheckout,
  resetRegisteredProjectCheckoutWarningCache,
} from "../registered-project-checkout.js";

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

function gitCallKeys(): string[] {
  return mockExecFileSync.mock.calls.map((call) => (call[1] as string[]).join(" "));
}

describe("syncRegisteredProjectCheckout", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetRegisteredProjectCheckoutWarningCache();
  });

  it("restores controller-only dirt and fast-forwards when already on the default branch", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "symbolic-ref --quiet --short HEAD": "main\n",
      "diff --name-only": ".beads/issues.jsonl\n",
      "diff --cached --name-only": "",
      "ls-files --others --exclude-standard": ".beads/last-touched\n",
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
    expect(mockExecFileSync).toHaveBeenCalledWith("git", ["reset", "--hard", "origin/main"], expect.objectContaining({ cwd: "/repo" }));
    // Already on the default branch — no checkout needed
    expect(gitCallKeys()).not.toContain("checkout main");

    expect(mockExecFileSync).toHaveBeenCalledWith(
      "git",
      ["fetch", "origin", "main", "--prune"],
      expect.objectContaining({
        cwd: "/repo",
        timeout: 30_000,
        env: expect.objectContaining({ GIT_TERMINAL_PROMPT: "0" }),
      }),
    );
  });

  it("never switches a checkout that is on a different branch (developer feature branch)", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "symbolic-ref --quiet --short HEAD": "feature/local\n",
      "fetch origin main:main": "",
    });
    const warn = vi.fn();

    syncRegisteredProjectCheckout({
      projectId: "foreman-b90e0",
      projectPath: "/repo",
      defaultBranch: "main",
      warn,
    });

    // Fetch still happened so refs stay fresh
    expect(mockExecFileSync).toHaveBeenCalledWith(
      "git",
      ["fetch", "origin", "main", "--prune"],
      expect.objectContaining({ cwd: "/repo" }),
    );
    // Local default-branch ref fast-forwarded without touching the checkout
    expect(mockExecFileSync).toHaveBeenCalledWith(
      "git",
      ["fetch", "origin", "main:main"],
      expect.objectContaining({ cwd: "/repo" }),
    );

    // No mutation of the developer's checkout
    const keys = gitCallKeys();
    expect(keys).not.toContain("checkout main");
    expect(keys.some((k) => k.startsWith("checkout -B"))).toBe(false);
    expect(keys).not.toContain("reset --hard origin/main");
    expect(mockRmSync).not.toHaveBeenCalled();

    // Warned that the checkout was skipped
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("feature/local"));
  });

  it("warns only once per project/branch state when sync skips the checkout repeatedly", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "symbolic-ref --quiet --short HEAD": "feature/local\n",
      "fetch origin main:main": "",
    });
    const warn = vi.fn();

    const options = {
      projectId: "foreman-b90e0",
      projectPath: "/repo",
      defaultBranch: "main",
      warn,
    };
    syncRegisteredProjectCheckout(options);
    syncRegisteredProjectCheckout(options);
    syncRegisteredProjectCheckout(options);

    expect(warn).toHaveBeenCalledTimes(1);
  });

  it("skips checkout on detached HEAD without mutating the working tree", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "symbolic-ref --quiet --short HEAD": new Error("not a symbolic ref"),
      "fetch origin main:main": "",
    });
    const warn = vi.fn();

    syncRegisteredProjectCheckout({
      projectId: "foreman-b90e0",
      projectPath: "/repo",
      defaultBranch: "main",
      warn,
    });

    const keys = gitCallKeys();
    expect(keys).not.toContain("checkout main");
    expect(keys).not.toContain("reset --hard origin/main");
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it("warns and skips fast-forward when non-controller changes exist", () => {
    setGitResponses({
      "fetch origin main --prune": "",
      "rev-parse --verify origin/main": "39eb3d7b\n",
      "symbolic-ref --quiet --short HEAD": "main\n",
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
    expect(gitCallKeys()).not.toContain("checkout main");
    expect(mockRmSync).not.toHaveBeenCalled();
  });
});
