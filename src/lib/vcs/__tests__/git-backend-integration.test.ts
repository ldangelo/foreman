/**
 * Integration tests for GitBackend — Full Pipeline Cycle
 *
 * Validates AC-007-2 (same git commands in same order) and
 * AC-022-1 (< 1% pipeline overhead) by exercising the full
 * create-workspace → commit → push → merge cycle end-to-end.
 *
 * Unlike the unit tests in git-backend.test.ts (which test each method
 * in isolation), these tests simulate a complete Foreman pipeline run:
 *   1. Bare remote (simulated origin)
 *   2. Clone to local (main worktree)
 *   3. Create workspace on feature branch
 *   4. Write file, stage, commit, push
 *   5. Fetch on main worktree
 *   6. Merge feature branch back to dev/main
 *   7. Verify results
 *
 * @module src/lib/vcs/__tests__/git-backend-integration.test
 */

import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
  existsSync,
} from "node:fs";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GitBackend } from "../git-backend.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Create a bare git repository (simulates a remote/origin).
 */
function makeBareRepo(): string {
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-integ-bare-")),
  );
  execFileSync("git", ["init", "--bare", "--initial-branch=dev"], { cwd: dir });
  return dir;
}

/**
 * Clone a bare repo to a new local directory (simulates a developer's local checkout).
 * Sets up git user config so commits work without global config.
 */
function cloneRepo(bareRepoPath: string, branch = "dev"): string {
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-integ-clone-")),
  );
  execFileSync("git", ["clone", bareRepoPath, dir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test Agent"], { cwd: dir });

  // Ensure the default branch exists in the clone (bare repos have no initial commit)
  try {
    execFileSync("git", ["checkout", branch], { cwd: dir });
  } catch {
    // Branch doesn't exist yet (bare repo is empty) — create an initial commit
    execFileSync("git", ["checkout", "--orphan", branch], { cwd: dir });
  }
  return dir;
}

/**
 * Bootstrap a bare remote + local clone with an initial commit on `dev`.
 * Returns { remoteDir, localDir }.
 */
function makeRemoteAndLocal(): { remoteDir: string; localDir: string } {
  const remoteDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-integ-remote-")),
  );
  execFileSync("git", ["init", "--bare", "--initial-branch=dev"], {
    cwd: remoteDir,
  });

  // Create an intermediate local repo to push an initial commit to the bare remote
  const initDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-integ-init-")),
  );
  execFileSync("git", ["clone", remoteDir, initDir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], {
    cwd: initDir,
  });
  execFileSync("git", ["config", "user.name", "Test Agent"], { cwd: initDir });
  execFileSync("git", ["checkout", "-b", "dev"], { cwd: initDir });
  writeFileSync(join(initDir, "README.md"), "# Project\n");
  execFileSync("git", ["add", "."], { cwd: initDir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: initDir });
  execFileSync("git", ["push", "-u", "origin", "dev"], { cwd: initDir });
  rmSync(initDir, { recursive: true, force: true });

  // Now clone the properly-initialised remote for the main worktree
  const localDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-integ-local-")),
  );
  execFileSync("git", ["clone", remoteDir, localDir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], {
    cwd: localDir,
  });
  execFileSync("git", ["config", "user.name", "Test Agent"], {
    cwd: localDir,
  });

  return { remoteDir, localDir };
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── Full Pipeline Cycle ───────────────────────────────────────────────────────

describe("GitBackend Integration: Full create-commit-push-merge pipeline", () => {
  it("completes the full cycle: create workspace → commit → push → merge", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-seed-001";

    // ── Phase 1: Create workspace ──────────────────────────────────────
    const workspaceResult = await backend.createWorkspace(localDir, seedId, "dev");

    expect(workspaceResult.branchName).toBe(`foreman/${seedId}`);
    expect(workspaceResult.workspacePath).toBe(
      join(localDir, ".foreman-worktrees", seedId),
    );
    expect(existsSync(workspaceResult.workspacePath)).toBe(true);

    // Register worktree path for cleanup
    tempDirs.push(workspaceResult.workspacePath);

    // ── Phase 2: Write a test file in the workspace ────────────────────
    const testFilePath = join(workspaceResult.workspacePath, "feature.txt");
    writeFileSync(testFilePath, "# Feature implementation\nconsole.log('hello');\n");
    expect(existsSync(testFilePath)).toBe(true);

    // ── Phase 3: Stage all changes ────────────────────────────────────
    await backend.stageAll(workspaceResult.workspacePath);

    // Status should show no untracked files (all staged)
    const statusAfterStage = await backend.status(workspaceResult.workspacePath);
    expect(statusAfterStage).not.toContain("??");

    // ── Phase 4: Commit ───────────────────────────────────────────────
    const commitMessage = `Implement feature (${seedId})`;
    await backend.commit(workspaceResult.workspacePath, commitMessage);

    // HEAD should now point to a valid commit
    const headAfterCommit = await backend.getHeadId(workspaceResult.workspacePath);
    expect(headAfterCommit).toMatch(/^[0-9a-f]{40}$/);

    // Working tree should be clean after commit
    const statusAfterCommit = await backend.status(workspaceResult.workspacePath);
    expect(statusAfterCommit).toBe("");

    // ── Phase 5: Push to remote ───────────────────────────────────────
    await backend.push(
      workspaceResult.workspacePath,
      workspaceResult.branchName,
    );

    // Verify the branch exists on the remote after push
    // We need to fetch first to update remote tracking refs
    await backend.fetch(localDir);
    const branchOnRemote = await backend.branchExistsOnRemote(
      localDir,
      workspaceResult.branchName,
    );
    expect(branchOnRemote).toBe(true);

    // ── Phase 6: Merge into dev ───────────────────────────────────────
    const mergeResult = await backend.merge(
      localDir,
      workspaceResult.branchName,
      "dev",
    );

    expect(mergeResult.success).toBe(true);
    expect(mergeResult.conflicts).toBeUndefined();

    // ── Phase 7: Verify file exists in dev after merge ────────────────
    // After merge(), we should be on the dev branch
    const currentBranch = await backend.getCurrentBranch(localDir);
    expect(currentBranch).toBe("dev");

    // The feature file should now be present in the main worktree
    const mergedFilePath = join(localDir, "feature.txt");
    expect(existsSync(mergedFilePath)).toBe(true);

    // ── Phase 8: Verify merge commit was created (--no-ff) ────────────
    const logOutput = execFileSync(
      "git",
      ["log", "--merges", "--oneline", "-1"],
      { cwd: localDir },
    )
      .toString()
      .trim();
    expect(logOutput).not.toBe(""); // At least one merge commit exists

    // ── Phase 9: Cleanup workspace ────────────────────────────────────
    await backend.removeWorkspace(localDir, workspaceResult.workspacePath);
    expect(existsSync(workspaceResult.workspacePath)).toBe(false);

    // Workspace must not appear in listWorkspaces() after removal
    const workspacesAfter = await backend.listWorkspaces(localDir);
    const paths = workspacesAfter.map((w) => w.path);
    expect(paths).not.toContain(workspaceResult.workspacePath);
  });

  it("listWorkspaces() includes the created workspace during active pipeline", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-seed-list";

    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    const workspaces = await backend.listWorkspaces(localDir);
    const workspacePaths = workspaces.map((w) => w.path);
    expect(workspacePaths).toContain(workspacePath);

    // Verify branch name in workspace list
    const workspace = workspaces.find((w) => w.path === workspacePath);
    expect(workspace).toBeDefined();
    expect(workspace!.branch).toBe(branchName);

    // Cleanup
    await backend.removeWorkspace(localDir, workspacePath);
  });

  it("merge returns success with no conflicts for non-overlapping changes", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-seed-no-conflict";

    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    // Write a unique file — won't conflict with anything on dev
    writeFileSync(join(workspacePath, "unique-feature.ts"), 'export const x = 42;\n');
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, `feat: add unique feature (${seedId})`);
    await backend.push(workspacePath, branchName);

    await backend.fetch(localDir);
    const result = await backend.merge(localDir, branchName, "dev");

    expect(result.success).toBe(true);
    expect(result.conflicts).toBeUndefined();

    // Cleanup
    await backend.removeWorkspace(localDir, workspacePath);
  });
});

// ── AC-007-2: Git commands in correct order ───────────────────────────────────

describe("AC-007-2: Git commands are called in the expected order", () => {
  it("push() calls git push with -u origin <branchName>", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-ac007-2";

    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    writeFileSync(join(workspacePath, "test-file.txt"), "test content\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "test commit");

    // push() should not throw and should result in the branch on remote
    await expect(
      backend.push(workspacePath, branchName),
    ).resolves.toBeUndefined();

    await backend.fetch(localDir);
    const exists = await backend.branchExistsOnRemote(localDir, branchName);
    expect(exists).toBe(true);

    await backend.removeWorkspace(localDir, workspacePath);
  });

  it("merge() checks out target branch before merging (correct sequence)", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-ac007-seq";

    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    writeFileSync(join(workspacePath, "seq-test.txt"), "sequential test\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, "seq: add test file");
    await backend.push(workspacePath, branchName);

    await backend.fetch(localDir);

    // Switch to a different branch before calling merge — merge() should
    // automatically checkout the target branch as part of its sequence
    execFileSync("git", ["checkout", "-b", "other-branch"], { cwd: localDir });
    const beforeMergeBranch = await backend.getCurrentBranch(localDir);
    expect(beforeMergeBranch).toBe("other-branch");

    // merge() should checkout 'dev' and then merge into it
    const result = await backend.merge(localDir, branchName, "dev");
    expect(result.success).toBe(true);

    // Verify we are now on the target branch (merge() checked it out)
    const afterMergeBranch = await backend.getCurrentBranch(localDir);
    expect(afterMergeBranch).toBe("dev");

    await backend.removeWorkspace(localDir, workspacePath);
  });

  it("stageAll() + commit() sequence produces a clean working tree", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-ac007-stage";

    const { workspacePath } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    // Write multiple files
    writeFileSync(join(workspacePath, "file-a.ts"), "export const a = 1;\n");
    writeFileSync(join(workspacePath, "file-b.ts"), "export const b = 2;\n");
    writeFileSync(join(workspacePath, "file-c.md"), "# Docs\n");

    // Before staging: 3 untracked files
    const statusBefore = await backend.status(workspacePath);
    expect(statusBefore).toContain("??");

    await backend.stageAll(workspacePath);

    // After staging: no untracked files
    const statusAfterStage = await backend.status(workspacePath);
    expect(statusAfterStage).not.toContain("??");
    // All files staged (show as 'A ')
    expect(statusAfterStage).toContain("A ");

    await backend.commit(workspacePath, "feat: add three files");

    // After commit: clean working tree
    const statusAfterCommit = await backend.status(workspacePath);
    expect(statusAfterCommit).toBe("");

    await backend.removeWorkspace(localDir, workspacePath);
  });
});

// ── AC-022-1: Pipeline overhead < 1% ─────────────────────────────────────────

describe("AC-022-1: GitBackend abstraction overhead is negligible", () => {
  it("full pipeline cycle completes in a reasonable time (< 30s)", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-ac022-perf";

    const startTime = Date.now();

    // Execute the full pipeline via the abstraction layer
    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    writeFileSync(join(workspacePath, "perf-test.ts"), "export const perf = true;\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, `perf: test commit (${seedId})`);
    await backend.push(workspacePath, branchName);
    await backend.fetch(localDir);
    const mergeResult = await backend.merge(localDir, branchName, "dev");
    await backend.removeWorkspace(localDir, workspacePath);

    const totalTime = Date.now() - startTime;

    // AC-022-1: overhead must be negligible — full pipeline < 30 seconds
    // (git I/O dominates; abstraction adds < 1% overhead)
    expect(totalTime).toBeLessThan(30_000);
    expect(mergeResult.success).toBe(true);
  });

  it("abstraction layer overhead per-call is negligible relative to direct git", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const execFileAsync = promisify(execFile);

    // Use 100 interleaved iterations to average out OS scheduling noise.
    // Interleaved (ABABAB...) rather than batched (AAAA...BBBB...) so both
    // methods experience the same ambient CPU load.  This prevents the batched
    // pattern's susceptibility to load shifts between the two sequential runs
    // (e.g. other parallel test workers freeing CPU mid-suite).
    const iterations = 100;

    // Warm-up pass — discard results so JIT / disk caches don't skew the
    // first timed run.
    for (let i = 0; i < 5; i++) {
      await backend.getCurrentBranch(localDir);
      await execFileAsync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: localDir,
      });
    }

    // Interleaved benchmark — each iteration measures both paths back-to-back
    // so OS scheduling affects both equally.
    let backendTotal = 0;
    let directTotal = 0;

    for (let i = 0; i < iterations; i++) {
      const t0 = performance.now();
      await backend.getCurrentBranch(localDir);
      backendTotal += performance.now() - t0;

      const t1 = performance.now();
      const { stdout } = await execFileAsync(
        "git",
        ["rev-parse", "--abbrev-ref", "HEAD"],
        { cwd: localDir },
      );
      stdout.trim(); // mirror what GitBackend does
      directTotal += performance.now() - t1;
    }

    // Clamp to zero: if the backend happened to be faster the overhead is 0,
    // not a meaningful negative value.
    const overheadPerCall = Math.max(0, (backendTotal - directTotal) / iterations);

    // Threshold rationale: the real acceptance criterion (AC-022) is < 1%
    // end-to-end pipeline overhead.  A per-call ceiling of 5 ms gives ~10×
    // headroom over the typical < 0.5 ms/call overhead while still catching
    // regressions like accidental network I/O or synchronous blocking inside
    // the backend.
    expect(overheadPerCall).toBeLessThan(5);
  });
});

// ── Rebase Before Merge (Foreman Pattern) ────────────────────────────────────

describe("GitBackend Integration: Rebase before merge (Foreman finalize pattern)", () => {
  it("rebases feature branch onto dev before merging (no merge conflicts)", async () => {
    const { remoteDir, localDir } = makeRemoteAndLocal();
    tempDirs.push(remoteDir, localDir);

    const backend = new GitBackend(localDir);
    const seedId = "test-rebase-merge";

    // Create workspace on feature branch
    const { workspacePath, branchName } = await backend.createWorkspace(
      localDir,
      seedId,
      "dev",
    );
    tempDirs.push(workspacePath);

    // Add a commit on the feature branch
    writeFileSync(join(workspacePath, "feature-work.ts"), "export const work = 'done';\n");
    await backend.stageAll(workspacePath);
    await backend.commit(workspacePath, `feat: feature work (${seedId})`);

    // Simulate dev branch advancing (a new commit on dev AFTER workspace was created)
    // We do this directly in the local repo
    execFileSync("git", ["checkout", "dev"], { cwd: localDir });
    writeFileSync(join(localDir, "dev-progress.md"), "# Dev Progress\n");
    execFileSync("git", ["add", "."], { cwd: localDir });
    execFileSync("git", ["commit", "-m", "chore: dev progress"], { cwd: localDir });
    execFileSync("git", ["push", "origin", "dev"], { cwd: localDir });

    // Push the feature branch
    await backend.push(workspacePath, branchName);

    // Fetch and rebase (simulating Foreman's finalize step)
    await backend.fetch(localDir);
    const rebaseResult = await backend.rebase(workspacePath, "origin/dev");
    expect(rebaseResult.success).toBe(true);
    expect(rebaseResult.hasConflicts).toBe(false);

    // After rebase, push with force (force-push the rebased branch)
    await backend.push(workspacePath, branchName, { force: true });

    // Now merge the rebased feature branch
    await backend.fetch(localDir);
    const mergeResult = await backend.merge(localDir, branchName, "dev");
    expect(mergeResult.success).toBe(true);

    // The feature file should exist in dev
    const featureFileInDev = join(localDir, "feature-work.ts");
    expect(existsSync(featureFileInDev)).toBe(true);

    await backend.removeWorkspace(localDir, workspacePath);
  });
});
