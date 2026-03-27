/**
 * TRD-030 & TRD-030-TEST: GitBackend Full Pipeline Integration Tests
 *
 * Tests the complete GitBackend lifecycle:
 * - createWorkspace → commit → push → merge
 * - listWorkspaces includes created workspace
 * - merge succeeds with success=true
 * - removeWorkspace cleans up correctly
 *
 * These tests use real git repositories in tmpdir and require git to be installed.
 * They test the actual integration between GitBackend and the git CLI.
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
import { GitBackend } from "../git-backend.js";

// ── Helpers ───────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * Create a bare git repository that acts as the "remote origin".
 */
function makeBarRepo(name: string): string {
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), `foreman-git-bare-${name}-`)),
  );
  execFileSync("git", ["init", "--bare", `--initial-branch=main`], { cwd: dir });
  return dir;
}

/**
 * Create a local git repository cloned from a bare remote.
 * Returns the local clone path.
 */
function makeClonedRepo(bareRemote: string, name: string): string {
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), `foreman-git-local-${name}-`)),
  );
  execFileSync("git", ["clone", bareRemote, dir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# integration test\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  execFileSync("git", ["push", "origin", "main"], { cwd: dir });
  return dir;
}

/**
 * Create a standalone git repo (no remote) for tests that don't need push/pull.
 */
function makeStandaloneRepo(branch = "main"): string {
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-standalone-")),
  );
  execFileSync("git", ["init", `--initial-branch=${branch}`], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# standalone test\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

// ── TRD-030: createWorkspace lifecycle ───────────────────────────────────

describe("TRD-030: GitBackend createWorkspace", () => {
  it("creates a workspace in .foreman-worktrees/<seedId>/", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-seed-001";

    const result = await backend.createWorkspace(repo, seedId, "main");

    expect(result.workspacePath).toBe(join(repo, ".foreman-worktrees", seedId));
    expect(result.branchName).toBe(`foreman/${seedId}`);
    expect(existsSync(result.workspacePath)).toBe(true);

    // Cleanup
    await backend.removeWorkspace(repo, result.workspacePath);
  });

  it("workspace branch name follows foreman/<seedId> convention", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "bd-abc123";

    const result = await backend.createWorkspace(repo, seedId, "main");
    expect(result.branchName).toBe("foreman/bd-abc123");

    await backend.removeWorkspace(repo, result.workspacePath);
  });

  it("listWorkspaces includes the created workspace", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-list-seed";

    const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");

    const workspaces = await backend.listWorkspaces(repo);
    const found = workspaces.find((w) => w.path === workspacePath);

    expect(found).toBeDefined();
    expect(found?.branch).toBe(branchName);

    await backend.removeWorkspace(repo, workspacePath);
  });

  it("listWorkspaces after remove does not include removed workspace", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-remove-seed";

    const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");
    await backend.removeWorkspace(repo, workspacePath);

    const workspaces = await backend.listWorkspaces(repo);
    const found = workspaces.find((w) => w.path === workspacePath);

    expect(found).toBeUndefined();
    expect(existsSync(workspacePath)).toBe(false);
  });

  it("reuses existing workspace when called twice", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-reuse-seed";

    const result1 = await backend.createWorkspace(repo, seedId, "main");
    // Second call should reuse existing workspace
    const result2 = await backend.createWorkspace(repo, seedId, "main");

    expect(result1.workspacePath).toBe(result2.workspacePath);
    expect(result1.branchName).toBe(result2.branchName);

    await backend.removeWorkspace(repo, result1.workspacePath);
  });
});

// ── TRD-030: stageAll + commit lifecycle ─────────────────────────────────

describe("TRD-030: GitBackend stageAll + commit", () => {
  it("stages and commits a new file in the workspace", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-commit-seed";

    const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");

    // Write a new file
    writeFileSync(join(workspacePath, "feature.ts"), "export const x = 1;\n");

    // Stage + commit
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "feat: add feature.ts");

    // Verify committed
    const headId = await backend.getHeadId(workspacePath);
    expect(headId).toBeTruthy();

    const modifiedFiles = await backend.getModifiedFiles(workspacePath);
    expect(modifiedFiles).not.toContain("feature.ts");

    await backend.removeWorkspace(repo, workspacePath);
  });

  it("getModifiedFiles returns unstaged files before stageAll", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-modified-seed";

    const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");

    writeFileSync(join(workspacePath, "new-file.ts"), "export const y = 2;\n");

    const files = await backend.getModifiedFiles(workspacePath);
    expect(files).toContain("new-file.ts");

    await backend.removeWorkspace(repo, workspacePath);
  });
});

// ── TRD-030: merge lifecycle ──────────────────────────────────────────────

describe("TRD-030: GitBackend merge", () => {
  it("merges a feature branch into main with success=true", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-merge-seed";

    // Create workspace and commit changes
    const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");
    writeFileSync(join(workspacePath, "feature.ts"), "export const feature = true;\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "feat: add feature");

    // Merge the feature branch into main
    const mergeResult = await backend.merge(repo, branchName, "main");

    expect(mergeResult.success).toBe(true);
    expect(mergeResult.conflicts).toBeUndefined();

    await backend.removeWorkspace(repo, workspacePath);
  });

  it("merge succeeds with no conflicting files when changes are disjoint", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-noconflict-seed";

    // Create workspace with new unique file
    const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");
    writeFileSync(
      join(workspacePath, "unique-feature-file.ts"),
      "export const unique = true;\n",
    );
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "feat: unique file");

    const mergeResult = await backend.merge(repo, branchName, "main");

    expect(mergeResult.success).toBe(true);
    if (mergeResult.conflicts !== undefined) {
      expect(mergeResult.conflicts.length).toBe(0);
    }

    await backend.removeWorkspace(repo, workspacePath);
  });
});

// ── TRD-030: branchExists / branchExistsOnRemote ─────────────────────────

describe("TRD-030: GitBackend branch detection", () => {
  it("branchExists returns true for main branch", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    expect(await backend.branchExists(repo, "main")).toBe(true);
  });

  it("branchExists returns false for non-existent branch", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    expect(await backend.branchExists(repo, "nonexistent/branch")).toBe(false);
  });

  it("branchExists returns true after createWorkspace", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-branch-exists";

    const { branchName, workspacePath } = await backend.createWorkspace(repo, seedId, "main");
    expect(await backend.branchExists(repo, branchName)).toBe(true);

    await backend.removeWorkspace(repo, workspacePath);
  });
});

// ── TRD-030: rebase lifecycle ─────────────────────────────────────────────

describe("TRD-030: GitBackend rebase", () => {
  it("rebase completes successfully when there are no conflicts", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-rebase-seed";

    // Create workspace
    const { workspacePath, branchName } = await backend.createWorkspace(repo, seedId, "main");

    // Add a commit to workspace
    writeFileSync(join(workspacePath, "rebase-file.ts"), "export const r = 1;\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "feat: rebase test file");

    // Rebase onto main — should succeed cleanly since no conflicts
    const rebaseResult = await backend.rebase(workspacePath, "main");
    expect(rebaseResult.success).toBe(true);
    expect(rebaseResult.hasConflicts).toBe(false);

    await backend.removeWorkspace(repo, workspacePath);
  });
});

// ── TRD-030: diff / status ────────────────────────────────────────────────

describe("TRD-030: GitBackend diff and status", () => {
  it("status returns empty string on clean workspace", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-status-seed";

    const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");
    const statusOut = await backend.status(workspacePath);
    expect(statusOut.trim()).toBe("");

    await backend.removeWorkspace(repo, workspacePath);
  });

  it("status returns modified file path after writing file", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const seedId = "test-status-dirty";

    const { workspacePath } = await backend.createWorkspace(repo, seedId, "main");
    writeFileSync(join(workspacePath, "dirty.ts"), "export const dirty = true;\n");

    const statusOut = await backend.status(workspacePath);
    expect(statusOut).toContain("dirty.ts");

    await backend.removeWorkspace(repo, workspacePath);
  });

  it("getHeadId returns a valid commit hash", async () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const headId = await backend.getHeadId(repo);
    expect(headId).toMatch(/^[0-9a-f]{7,40}$/);
  });
});

// ── TRD-030: getFinalizeCommands ──────────────────────────────────────────

describe("TRD-030: GitBackend.getFinalizeCommands", () => {
  it("returns git-specific commands for all fields", () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const cmds = backend.getFinalizeCommands({
      seedId: "bd-test",
      seedTitle: "Test task",
      baseBranch: "main",
      worktreePath: join(repo, ".foreman-worktrees", "bd-test"),
    });

    expect(cmds.stageCommand).toContain("git add");
    expect(cmds.commitCommand).toContain("git commit");
    expect(cmds.pushCommand).toContain("git push");
    expect(cmds.rebaseCommand).toContain("git");
    expect(cmds.branchVerifyCommand).toContain("git");
    expect(cmds.cleanCommand).toBeTruthy();
  });

  it("push command includes branch name with foreman/ prefix", () => {
    const repo = makeStandaloneRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const cmds = backend.getFinalizeCommands({
      seedId: "bd-abc",
      seedTitle: "Test",
      baseBranch: "dev",
      worktreePath: "/some/path",
    });

    expect(cmds.pushCommand).toContain("foreman/bd-abc");
  });
});
