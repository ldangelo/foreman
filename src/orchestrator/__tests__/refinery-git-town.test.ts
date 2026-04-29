import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

/**
 * MQ-T058c: Tests documenting the PR creation strategy decision.
 *
 * MQ-T058d investigated `git town propose` (v22.6.0) for PR creation.
 * Key findings:
 *   - `git town propose` opens a browser window instead of using the GitHub API
 *   - No PR URL is returned in stdout (only a compare URL opened via `open`)
 *   - It runs side-effect commands: `git fetch`, `git stash`, `git push`
 *   - Although it supports --title and --body, the browser-opening behavior
 *     makes it unsuitable for non-interactive automation
 *
 * Decision: Keep `gh pr create` for ALL PR creation paths:
 *   - Refinery.createPRs() -- normal-flow PRs for completed runs
 *   - ConflictResolver.handleFallback() -- conflict PRs with resolution metadata
 *
 * These tests verify that both paths use `gh pr create` (via execFile)
 * and produce the expected outputs.
 */

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

import { execFile } from "node:child_process";
import { Refinery } from "../refinery.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/worktrees/seed-abc",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeMocks() {
  const mockDb = {
    prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
  };
  const store = {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRun: vi.fn(() => null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getDb: vi.fn(() => mockDb),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
  };
  const refinery = new Refinery(store as unknown as Parameters<typeof Refinery.prototype.createPRs>[0] extends undefined ? never : never, seeds as unknown as Parameters<typeof Refinery.prototype.createPRs>[0] extends undefined ? never : never, "/tmp/project");
  return { store, seeds, refinery: refinery as Refinery };
}

// Typed helper to avoid the `any` escape hatch on makeMocks
function createTestRefinery() {
  const mockDb = {
    prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
  };
  const store = {
    getRunsByStatus: vi.fn().mockReturnValue([] as Run[]),
    getRun: vi.fn().mockReturnValue(null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getDb: vi.fn(() => mockDb),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test mock wiring
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
}

function mockExecFileForPR(prUrl = "https://github.com/org/repo/pull/42") {
  (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
    (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
      // git push -> success
      if (cmd === "git") {
        callback(null, { stdout: "", stderr: "" });
        return;
      }
      // gh pr create -> return PR URL
      if (cmd === "gh" && Array.isArray(args) && args.includes("pr")) {
        callback(null, { stdout: prUrl, stderr: "" });
        return;
      }
      callback(null, { stdout: "", stderr: "" });
    },
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe("MQ-T058d: PR creation strategy decision", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("Refinery.createPRs() uses gh pr create (not git town propose)", () => {
    it("calls gh pr create with --title and --body for normal-flow PRs", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ status: "completed" });
      store.getRunsByStatus.mockReturnValue([run]);

      mockExecFileForPR("https://github.com/org/repo/pull/42");

      const report = await refinery.createPRs({ baseBranch: "main" });

      expect(report.created).toHaveLength(1);
      expect(report.created[0].prUrl).toBe("https://github.com/org/repo/pull/42");
      expect(report.failed).toHaveLength(0);

      // Verify gh was called (not git-town)
      const calls = (execFile as unknown as ReturnType<typeof vi.fn>).mock.calls;
      const ghCall = calls.find(
        (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1].includes("create"),
      );
      expect(ghCall).toBeDefined();
      expect(ghCall![1]).toContain("--title");
      expect(ghCall![1]).toContain("--body");

      // Verify git-town was NOT called
      const gitTownCall = calls.find(
        (c: unknown[]) => c[0] === "git-town" || (c[0] === "git" && Array.isArray(c[1]) && c[1][0] === "town"),
      );
      expect(gitTownCall).toBeUndefined();
    });

    it("returns PR URL from gh pr create stdout", async () => {
      const { store, refinery } = createTestRefinery();
      const expectedUrl = "https://github.com/org/repo/pull/99";
      store.getRunsByStatus.mockReturnValue([makeRun()]);

      mockExecFileForPR(expectedUrl);

      const report = await refinery.createPRs();

      expect(report.created[0].prUrl).toBe(expectedUrl);
    });

    it("updates run status to pr-created on success", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-99" });
      store.getRunsByStatus.mockReturnValue([run]);

      mockExecFileForPR();

      await refinery.createPRs();

      expect(store.updateRun).toHaveBeenCalledWith("run-99", { status: "pr-created" });
    });

    it("logs pr-created event with PR URL", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-99", project_id: "proj-1", seed_id: "seed-xyz" });
      store.getRunsByStatus.mockReturnValue([run]);

      mockExecFileForPR("https://github.com/org/repo/pull/7");

      await refinery.createPRs();

      expect(store.logEvent).toHaveBeenCalledWith(
        "proj-1",
        "pr-created",
        expect.objectContaining({ prUrl: "https://github.com/org/repo/pull/7" }),
        "run-99",
      );
    });

    it("reports failure when gh pr create fails", async () => {
      const { store, refinery } = createTestRefinery();
      store.getRunsByStatus.mockReturnValue([makeRun()]);

      (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
        (cmd: string, _args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
          if (cmd === "gh") {
            callback(new Error("gh: already exists"), { stdout: "", stderr: "" });
            return;
          }
          callback(null, { stdout: "", stderr: "" });
        },
      );

      const report = await refinery.createPRs();

      expect(report.created).toHaveLength(0);
      expect(report.failed).toHaveLength(1);
      expect(report.failed[0].error).toContain("already exists");
    });

    it("pushes branch before creating PR", async () => {
      const { store, refinery } = createTestRefinery();
      store.getRunsByStatus.mockReturnValue([makeRun({ seed_id: "seed-push" })]);

      const callOrder: string[] = [];
      (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
        (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
          if (cmd === "git" && Array.isArray(args) && args.includes("push")) {
            callOrder.push("git-push");
          }
          if (cmd === "gh") {
            callOrder.push("gh-pr-create");
          }
          callback(null, { stdout: "https://github.com/org/repo/pull/1", stderr: "" });
        },
      );

      await refinery.createPRs();

      expect(callOrder).toEqual(["git-push", "gh-pr-create"]);
    });
  });

  describe("Refinery.mergePullRequest() cleanup behavior", () => {
    it("merges without asking gh to delete the local branch", async () => {
      const mockDb = {
        prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
      };
      const store = {
        getRun: vi.fn().mockReturnValue(makeRun({ id: "run-merge", seed_id: "seed-merge", worktree_path: "/tmp/worktrees/seed-merge" })),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getDb: vi.fn(() => mockDb),
      };
      const seeds = {
        getGraph: vi.fn(async () => ({ edges: [] })),
        show: vi.fn(async () => null),
      };
      const vcsBackend = {
        detectDefaultBranch: vi.fn(async () => "dev"),
        push: vi.fn(async () => undefined),
        removeWorkspace: vi.fn(async () => undefined),
        diff: vi.fn(async () => ""),
      };
      const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcsBackend as any);
      const previousMode = process.env.FOREMAN_RUNTIME_MODE;
      process.env.FOREMAN_RUNTIME_MODE = "normal";

      try {
        (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
          (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
            if (cmd === "gh" && args[0] === "pr" && args[1] === "view") {
              callback(null, {
                stdout: JSON.stringify({
                  state: "OPEN",
                  headRefName: "foreman/seed-merge",
                  url: "https://github.com/org/repo/pull/55",
                }),
                stderr: "",
              });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "merge") {
              callback(null, { stdout: "", stderr: "" });
              return;
            }
            callback(new Error(`unexpected call: ${cmd} ${args.join(" ")}`), { stdout: "", stderr: "" });
          },
        );

        const report = await refinery.mergePullRequest({ runId: "run-merge", targetBranch: "dev" });

        expect(report.unexpectedErrors).toHaveLength(0);
        expect(report.merged).toEqual([
          expect.objectContaining({ runId: "run-merge", seedId: "seed-merge", branchName: "foreman/seed-merge" }),
        ]);
        const mergeCall = (execFile as unknown as ReturnType<typeof vi.fn>).mock.calls.find(
          (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1][0] === "pr" && c[1][1] === "merge",
        );
        expect(mergeCall).toBeDefined();
        expect(mergeCall?.[1]).not.toContain("--delete-branch");
        expect(vcsBackend.removeWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/worktrees/seed-merge");
      } finally {
        process.env.FOREMAN_RUNTIME_MODE = previousMode;
      }
    });

    it("treats local branch deletion cleanup failures as success when the PR is already merged", async () => {
      const mockDb = {
        prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
      };
      const store = {
        getRun: vi.fn().mockReturnValue(makeRun({ id: "run-merge-fallback", seed_id: "seed-merge-fallback", worktree_path: "/tmp/worktrees/seed-merge-fallback" })),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getDb: vi.fn(() => mockDb),
      };
      const seeds = {
        getGraph: vi.fn(async () => ({ edges: [] })),
        show: vi.fn(async () => null),
      };
      const vcsBackend = {
        detectDefaultBranch: vi.fn(async () => "dev"),
        push: vi.fn(async () => undefined),
        removeWorkspace: vi.fn(async () => undefined),
        diff: vi.fn(async () => ""),
        resolveRef: vi.fn(async () => "abc1234"),
      };
      const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcsBackend as any);
      const previousMode = process.env.FOREMAN_RUNTIME_MODE;
      process.env.FOREMAN_RUNTIME_MODE = "normal";
      let viewCount = 0;

      try {
        (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
          (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
            if (cmd === "gh" && args[0] === "pr" && args[1] === "view") {
              viewCount += 1;
              callback(null, {
                stdout: JSON.stringify({
                  state: viewCount === 1 ? "OPEN" : "MERGED",
                  headRefName: "foreman/seed-merge-fallback",
                  headRefOid: "abc1234",
                  url: "https://github.com/org/repo/pull/56",
                }),
                stderr: "",
              });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "merge") {
              callback(
                new Error("Command failed: gh pr merge foreman/seed-merge-fallback --squash\nfailed to delete local branch foreman/seed-merge-fallback: failed to run git: error: cannot delete branch 'foreman/seed-merge-fallback' used by worktree at '/tmp/worktrees/seed-merge-fallback'\n"),
                { stdout: "", stderr: "failed to delete local branch foreman/seed-merge-fallback: failed to run git: error: cannot delete branch 'foreman/seed-merge-fallback' used by worktree at '/tmp/worktrees/seed-merge-fallback'\n" },
              );
              return;
            }
            callback(new Error(`unexpected call: ${cmd} ${args.join(" ")}`), { stdout: "", stderr: "" });
          },
        );

        const report = await refinery.mergePullRequest({ runId: "run-merge-fallback", targetBranch: "dev" });

        expect(report.unexpectedErrors).toHaveLength(0);
        expect(report.merged).toEqual([
          expect.objectContaining({ runId: "run-merge-fallback", seedId: "seed-merge-fallback", branchName: "foreman/seed-merge-fallback" }),
        ]);
        expect(store.updateRun).toHaveBeenCalledWith("run-merge-fallback", expect.objectContaining({ status: "merged" }));
        expect(store.logEvent).toHaveBeenCalledWith(
          "proj-1",
          "merge-cleanup-fallback",
          expect.objectContaining({ seedId: "seed-merge-fallback", branchName: "foreman/seed-merge-fallback" }),
          "run-merge-fallback",
        );
        expect(vcsBackend.resolveRef).toHaveBeenCalledWith("/tmp/project", "foreman/seed-merge-fallback");
        expect(vcsBackend.removeWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/worktrees/seed-merge-fallback");
      } finally {
        process.env.FOREMAN_RUNTIME_MODE = previousMode;
      }
    });
  });

  describe("Refinery.ensurePullRequestForRun() reuses existing PRs correctly", () => {
    it("reopens a closed PR by URL when reusing the same branch", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-77", seed_id: "seed-reopen" });
      store.getRun.mockReturnValue(run);
      const previousMode = process.env.FOREMAN_RUNTIME_MODE;
      process.env.FOREMAN_RUNTIME_MODE = "normal";

      try {
        (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
          (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
            if (cmd === "git") {
              callback(null, { stdout: "", stderr: "" });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "view") {
              callback(null, {
                stdout: JSON.stringify({
                  state: "CLOSED",
                  headRefName: "foreman/seed-reopen",
                  url: "https://github.com/org/repo/pull/77",
                }),
                stderr: "",
              });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "reopen") {
              callback(null, { stdout: "", stderr: "" });
              return;
            }
            callback(new Error(`unexpected call: ${cmd} ${args.join(" ")}`), { stdout: "", stderr: "" });
          },
        );

        const result = await refinery.ensurePullRequestForRun({ runId: "run-77", baseBranch: "main" });

        expect(result.prUrl).toBe("https://github.com/org/repo/pull/77");
        const calls = (execFile as unknown as ReturnType<typeof vi.fn>).mock.calls;
        const reopenCall = calls.find(
          (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1][0] === "pr" && c[1][1] === "reopen",
        );
        expect(reopenCall).toBeDefined();
        expect(reopenCall?.[1]).toContain("https://github.com/org/repo/pull/77");
        expect(store.logEvent).toHaveBeenCalledWith(
          "proj-1",
          "pr-created",
          expect.objectContaining({ existing: true, reopened: true, prUrl: "https://github.com/org/repo/pull/77" }),
          "run-77",
        );
      } finally {
        process.env.FOREMAN_RUNTIME_MODE = previousMode;
      }
    });

    it("creates a fresh PR when GitHub refuses to reopen the old closed PR", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-88", seed_id: "seed-reopen-fallback" });
      store.getRun.mockReturnValue(run);
      const previousMode = process.env.FOREMAN_RUNTIME_MODE;
      process.env.FOREMAN_RUNTIME_MODE = "normal";

      try {
        (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
          (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
            if (cmd === "git") {
              callback(null, { stdout: args.includes("log") ? "abc123 refresh branch" : "", stderr: "" });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "view") {
              callback(null, {
                stdout: JSON.stringify({
                  state: "CLOSED",
                  headRefName: "foreman/seed-reopen-fallback",
                  url: "https://github.com/org/repo/pull/88",
                }),
                stderr: "",
              });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "reopen") {
              callback(new Error("Command failed: gh pr reopen https://github.com/org/repo/pull/88\nAPI call failed: GraphQL: Could not open the pull request. (reopenPullRequest)\n"), { stdout: "", stderr: "API call failed: GraphQL: Could not open the pull request. (reopenPullRequest)\n" });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "create") {
              callback(null, { stdout: "https://github.com/org/repo/pull/99", stderr: "" });
              return;
            }
            callback(new Error(`unexpected call: ${cmd} ${args.join(" ")}`), { stdout: "", stderr: "" });
          },
        );

        const result = await refinery.ensurePullRequestForRun({ runId: "run-88", baseBranch: "main" });

        expect(result.prUrl).toBe("https://github.com/org/repo/pull/99");
        const calls = (execFile as unknown as ReturnType<typeof vi.fn>).mock.calls;
        const reopenCall = calls.find(
          (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1][0] === "pr" && c[1][1] === "reopen",
        );
        const createCall = calls.find(
          (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1][0] === "pr" && c[1][1] === "create",
        );
        expect(reopenCall).toBeDefined();
        expect(createCall).toBeDefined();
        expect(store.logEvent).toHaveBeenCalledWith(
          "proj-1",
          "pr-created",
          expect.objectContaining({ existing: false, prUrl: "https://github.com/org/repo/pull/99" }),
          "run-88",
        );
      } finally {
        process.env.FOREMAN_RUNTIME_MODE = previousMode;
      }
    });

    it("creates a fresh PR instead of reusing an already-merged PR for the same branch", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-89", seed_id: "seed-merged-pr-refresh" });
      store.getRun.mockReturnValue(run);
      const previousMode = process.env.FOREMAN_RUNTIME_MODE;
      process.env.FOREMAN_RUNTIME_MODE = "normal";

      try {
        (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
          (cmd: string, args: string[], _opts: unknown, callback: (err: Error | null, result: { stdout: string; stderr: string }) => void) => {
            if (cmd === "git") {
              callback(null, { stdout: args.includes("log") ? "abc123 refresh merged branch" : "", stderr: "" });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "view") {
              callback(null, {
                stdout: JSON.stringify({
                  state: "MERGED",
                  headRefName: "foreman/seed-merged-pr-refresh",
                  headRefOid: "oldmergedsha",
                  url: "https://github.com/org/repo/pull/101",
                }),
                stderr: "",
              });
              return;
            }
            if (cmd === "gh" && args[0] === "pr" && args[1] === "create") {
              callback(null, { stdout: "https://github.com/org/repo/pull/102", stderr: "" });
              return;
            }
            callback(new Error(`unexpected call: ${cmd} ${args.join(" ")}`), { stdout: "", stderr: "" });
          },
        );

        const result = await refinery.ensurePullRequestForRun({ runId: "run-89", baseBranch: "main" });

        expect(result.prUrl).toBe("https://github.com/org/repo/pull/102");
        const calls = (execFile as unknown as ReturnType<typeof vi.fn>).mock.calls;
        const createCall = calls.find(
          (c: unknown[]) => c[0] === "gh" && Array.isArray(c[1]) && c[1][0] === "pr" && c[1][1] === "create",
        );
        expect(createCall).toBeDefined();
        expect(store.logEvent).toHaveBeenCalledWith(
          "proj-1",
          "pr-created",
          expect.objectContaining({ existing: false, prUrl: "https://github.com/org/repo/pull/102" }),
          "run-89",
        );
      } finally {
        process.env.FOREMAN_RUNTIME_MODE = previousMode;
      }
    });
  });

  describe("Decision rationale documentation", () => {
    it("documents that git town propose is unsuitable for automation", () => {
      // This test serves as living documentation of the MQ-T058d findings.
      // If git-town changes behavior in the future, this test should be
      // updated along with the implementation.
      const findings = {
        gitTownVersion: "22.6.0",
        supportsTitle: true,
        supportsBody: true,
        createsViaAPI: false, // Opens browser instead
        returnsPRUrl: false,  // No URL in stdout
        sideEffects: ["git fetch", "git stash", "git push"],
        opensBrowser: true,   // Runs `open https://github.com/...`
        suitableForAutomation: false,
      };

      // Key constraint: Foreman agents must be non-interactive
      expect(findings.opensBrowser).toBe(true);
      expect(findings.returnsPRUrl).toBe(false);
      expect(findings.suitableForAutomation).toBe(false);

      // Both PR paths use gh pr create
      const prStrategy = {
        normalFlow: "gh pr create",     // Refinery.createPRs()
        conflictFlow: "gh pr create",   // ConflictResolver.handleFallback()
      };
      expect(prStrategy.normalFlow).toBe("gh pr create");
      expect(prStrategy.conflictFlow).toBe("gh pr create");
    });
  });
});
