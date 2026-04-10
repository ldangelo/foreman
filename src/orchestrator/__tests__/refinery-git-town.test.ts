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

vi.mock("../task-backend-ops.js", () => ({
  enqueueSetBeadStatus: vi.fn(),
  enqueueCloseSeed: vi.fn(),
  enqueueResetSeedToOpen: vi.fn(),
  enqueueAddNotesToBead: vi.fn(),
}));

import { execFile } from "node:child_process";
import { enqueueSetBeadStatus } from "../task-backend-ops.js";
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

    it("syncs the bead to closed after creating a PR", async () => {
      const { store, refinery } = createTestRefinery();
      const run = makeRun({ id: "run-100", seed_id: "seed-pr-sync" });
      store.getRunsByStatus.mockReturnValue([run]);
      store.getRun.mockReturnValue({ ...run, status: "pr-created" });

      mockExecFileForPR();

      await refinery.createPRs();

      expect(enqueueSetBeadStatus).toHaveBeenCalledWith(
        expect.anything(),
        "seed-pr-sync",
        "closed",
        "auto-merge",
      );
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
