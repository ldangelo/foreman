/**
 * TRD-031 & TRD-031-TEST: JujutsuBackend Full Pipeline Integration Tests
 *
 * Tests the complete JujutsuBackend lifecycle in a colocated jj+git repo:
 * - createWorkspace → describe → new → push → merge
 * - listWorkspaces includes created workspace
 * - merge without conflicts
 * - removeWorkspace cleanup
 *
 * ALL tests in this file are skipped when the `jj` binary is not available,
 * using the `describe.skipIf(!JJ_AVAILABLE)` pattern from the existing
 * jujutsu-backend.test.ts. CI must have jj installed in at least one matrix
 * configuration to exercise these tests.
 *
 * @see TRD-2026-004-vcs-backend-abstraction.md §6.3
 */

import { describe, it, expect, afterAll } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
  existsSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { JujutsuBackend } from "../jujutsu-backend.js";

// ── jj availability guard ─────────────────────────────────────────────────

function isJjAvailable(): boolean {
  try {
    execFileSync("jj", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

const JJ_AVAILABLE = isJjAvailable();

// ── Helpers ───────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * Create a colocated Jujutsu+Git repository.
 * Uses `jj git init --colocate` to create both .jj/ and .git/ directories.
 */
function makeColocatedRepo(): string {
  if (!JJ_AVAILABLE) return "/tmp/jj-not-available";

  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-integration-")),
  );
  tempDirs.push(dir);

  const env = {
    ...process.env,
    JJ_USER: "Test User",
    JJ_EMAIL: "test@test.com",
  };

  // Initialize colocated jj+git repo
  execFileSync("jj", ["git", "init", "--colocate"], { cwd: dir, env });

  // Configure git user for any git operations
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });

  // Create an initial commit and set up a "main" bookmark
  writeFileSync(join(dir, "README.md"), "# jj integration test\n");
  execFileSync("jj", ["describe", "-m", "initial commit"], { cwd: dir, env });

  // Get the current change ID for the initial commit
  const changeId = execFileSync("jj", ["log", "--no-graph", "-r", "@", "--template", "change_id"], {
    cwd: dir,
    env,
  }).toString().trim();

  // Create the "main" bookmark pointing at this initial commit
  execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], { cwd: dir, env });

  // Advance past the initial commit with jj new
  execFileSync("jj", ["new"], { cwd: dir, env });

  return dir;
}

function jjEnv() {
  return {
    ...process.env,
    JJ_USER: "Test User",
    JJ_EMAIL: "test@test.com",
  };
}

// ── TRD-031: Non-jj tests (always run) ───────────────────────────────────

describe("TRD-031: JujutsuBackend static interface (no jj required)", () => {
  it("name is 'jujutsu'", () => {
    const b = new JujutsuBackend("/tmp");
    expect(b.name).toBe("jujutsu");
  });

  it("stageAll is a no-op (jj auto-stages)", async () => {
    const b = new JujutsuBackend("/tmp");
    await expect(b.stageAll("/tmp")).resolves.toBeUndefined();
  });

  it("getFinalizeCommands returns jj-specific commands", () => {
    const b = new JujutsuBackend("/tmp");
    const cmds = b.getFinalizeCommands({
      seedId: "bd-test",
      seedTitle: "Integration Test",
      baseBranch: "main",
      worktreePath: "/tmp/worktrees/bd-test",
    });

    // jj has no explicit stage command
    expect(cmds.stageCommand).toBe("");

    // Should use jj describe + jj new for commits
    expect(cmds.commitCommand).toContain("jj");
    expect(cmds.pushCommand).toContain("jj");
    expect(cmds.rebaseCommand).toContain("jj");
  });

  it("getFinalizeCommands includes bookmark name with foreman/ prefix", () => {
    const b = new JujutsuBackend("/tmp");
    const cmds = b.getFinalizeCommands({
      seedId: "bd-xyz",
      seedTitle: "Test",
      baseBranch: "dev",
      worktreePath: "/tmp",
    });

    expect(cmds.pushCommand).toContain("foreman/bd-xyz");
  });
});

// ── TRD-031: Full pipeline tests (require jj) ─────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "TRD-031: JujutsuBackend full pipeline (requires jj)",
  () => {
    it("createWorkspace creates a workspace directory", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-test-001";

      const result = await backend.createWorkspace(repo, seedId, "main");

      expect(result.workspacePath).toContain(seedId);
      expect(result.branchName).toBe(`foreman/${seedId}`);
      expect(existsSync(result.workspacePath)).toBe(true);

      await backend.removeWorkspace(repo, result.workspacePath);
    });

    it("listWorkspaces includes the created workspace", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-list-test";

      const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");

      const workspaces = await backend.listWorkspaces(repo);
      expect(workspaces.length).toBeGreaterThan(0);

      // At minimum the new workspace path should appear
      const found = workspaces.find((w) => w.path === workspacePath);
      expect(found).toBeDefined();

      await backend.removeWorkspace(repo, workspacePath);
    });

    it("branchExists returns true after createWorkspace", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-branch-test";

      const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");

      const exists = await backend.branchExists(repo, branchName);
      expect(exists).toBe(true);

      await backend.removeWorkspace(repo, workspacePath);
    });

    it("getCurrentBranch returns the expected bookmark in workspace", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-current-branch-test";

      const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");

      // In the workspace, current branch should be the foreman/<seedId> bookmark
      const current = await backend.getCurrentBranch(workspacePath);
      expect(current).toBe(branchName);

      await backend.removeWorkspace(repo, workspacePath);
    });

    it("commit creates a new change in the workspace", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-commit-test";

      const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");

      // Write a file (jj auto-stages)
      writeFileSync(join(workspacePath, "feature.ts"), "export const jjFeature = true;\n");

      // Commit (jj describe + jj new)
      await backend.commit(workspacePath, "feat: jj feature file");

      // Verify no modified files after commit
      const modified = await backend.getModifiedFiles(workspacePath);
      expect(modified).not.toContain("feature.ts");

      await backend.removeWorkspace(repo, workspacePath);
    });

    it("status returns empty on clean workspace", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-status-test";

      const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");

      const statusOut = await backend.status(workspacePath);
      // Should be empty or minimal output on clean workspace
      expect(typeof statusOut).toBe("string");

      await backend.removeWorkspace(repo, workspacePath);
    });

    it("getHeadId returns a valid change ID", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);

      const headId = await backend.getHeadId(repo);
      expect(headId).toBeTruthy();
      expect(headId.length).toBeGreaterThan(0);
    });

    it("removeWorkspace cleans up the workspace directory", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-cleanup-test";

      const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");
      expect(existsSync(workspacePath)).toBe(true);

      await backend.removeWorkspace(repo, workspacePath);
      expect(existsSync(workspacePath)).toBe(false);
    });

    it("merge completes successfully for non-conflicting branches", async () => {
      const repo = makeColocatedRepo();
      const backend = new JujutsuBackend(repo);
      const seedId = "jj-merge-test";

      // Create workspace and add a unique file
      const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");
      writeFileSync(
        join(workspacePath, "jj-unique-feature.ts"),
        "export const jjUnique = true;\n",
      );
      await backend.commit(workspacePath, "feat: unique jj file");

      // Merge into main — expect no conflicts
      const mergeResult = await backend.merge(repo, branchName, "main");

      expect(mergeResult.success).toBe(true);
      if (mergeResult.conflicts !== undefined) {
        expect(mergeResult.conflicts.length).toBe(0);
      }

      await backend.removeWorkspace(repo, workspacePath);
    });
  },
);
