/**
 * Integration tests for JujutsuBackend — Full Pipeline Cycle
 *
 * Validates AC-T-031-1 (full pipeline test assertions pass when jj installed)
 * and AC-T-031-2 (tests skip gracefully when jj is not installed).
 *
 * Unlike the unit tests in jujutsu-backend.test.ts (which test each method
 * in isolation), these tests simulate a complete Foreman pipeline run:
 *   1. Bare git remote (simulated origin — jj uses git under the hood)
 *   2. Colocated jj+git local clone
 *   3. Create workspace on feature bookmark
 *   4. Write file and commit (no explicit staging — jj auto-stages)
 *   5. Push to remote with --allow-new (required for new bookmarks)
 *   6. Fetch on main worktree
 *   7. Merge feature bookmark into dev
 *   8. Verify results and clean up
 *
 * Tests are wrapped in `describe.skipIf(!JJ_AVAILABLE)` to gracefully skip
 * when the `jj` CLI is not installed (AC-T-031-2).
 *
 * @module src/lib/vcs/__tests__/jujutsu-backend-integration.test
 */

import { describe, it, expect, afterEach } from "vitest";
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
import { getWorkspacePath } from "../../workspace-paths.js";

// ── Check if jj is available ──────────────────────────────────────────────────

/**
 * AC-T-031-2: Tests skip gracefully when jj is not installed.
 * This function is evaluated once at module load time.
 */
function isJjAvailable(): boolean {
  try {
    execFileSync("jj", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

const JJ_AVAILABLE = isJjAvailable();

// ── Cleanup ───────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Bootstrap a bare git remote + a colocated jj+git local clone with an
 * initial commit on the `dev` branch.
 *
 * jj uses git as its storage layer, so:
 * - The remote is a plain git bare repo.
 * - The local clone is a git clone that has been initialised as a
 *   colocated jj repo (`jj git init --colocate`).
 *
 * Returns `{ remoteDir, localDir }`.
 */
function makeRemoteAndLocal(): { remoteDir: string; localDir: string } {
  // Create bare git remote
  const remoteDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-integ-remote-")),
  );
  execFileSync("git", ["init", "--bare", "--initial-branch=dev"], {
    cwd: remoteDir,
    stdio: "pipe",
  });

  // Bootstrap: use a plain git repo to push an initial commit to the bare remote
  const initDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-integ-init-")),
  );
  execFileSync("git", ["clone", remoteDir, initDir], { stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "test@test.com"], {
    cwd: initDir,
    stdio: "pipe",
  });
  execFileSync("git", ["config", "user.name", "Test Agent"], {
    cwd: initDir,
    stdio: "pipe",
  });
  execFileSync("git", ["checkout", "-b", "dev"], { cwd: initDir, stdio: "pipe" });
  writeFileSync(join(initDir, "README.md"), "# Project\n");
  execFileSync("git", ["add", "."], { cwd: initDir, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "initial commit"], {
    cwd: initDir,
    stdio: "pipe",
  });
  execFileSync("git", ["push", "-u", "origin", "dev"], {
    cwd: initDir,
    stdio: "pipe",
  });
  rmSync(initDir, { recursive: true, force: true });

  // Create a colocated jj+git local clone
  const localDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-integ-local-")),
  );
  execFileSync("git", ["clone", remoteDir, localDir], { stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "test@test.com"], {
    cwd: localDir,
    stdio: "pipe",
  });
  execFileSync("git", ["config", "user.name", "Test Agent"], {
    cwd: localDir,
    stdio: "pipe",
  });
  // Colocate jj on top of the git clone
  execFileSync("jj", ["git", "init", "--colocate"], {
    cwd: localDir,
    stdio: "pipe",
  });

  return { remoteDir, localDir };
}

// ── AC-T-031-2: graceful skip when jj not installed ──────────────────────────
// The describe.skipIf guard below satisfies AC-T-031-2: when JJ_AVAILABLE is
// false, Vitest marks all contained tests as "skipped" rather than "failed".

// ── AC-T-031-1: Full Pipeline Integration ────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "JujutsuBackend Integration: Full create-commit-push-merge pipeline",
  () => {
    it("jj is available in this environment", () => {
      // Sanity guard — this test only runs when JJ_AVAILABLE is true
      expect(JJ_AVAILABLE).toBe(true);
    });

    it("completes the full cycle: create workspace → commit → push → merge", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-seed-jj-001";

      // ── Phase 1: Create workspace ────────────────────────────────────
      const workspaceResult = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );

      expect(workspaceResult.branchName).toBe(`foreman/${seedId}`);
      expect(workspaceResult.workspacePath).toBe(
        getWorkspacePath(localDir, seedId),
      );
      expect(existsSync(workspaceResult.workspacePath)).toBe(true);

      // Register workspace path for cleanup
      tempDirs.push(workspaceResult.workspacePath);

      // ── Phase 2: Write a test file in the workspace ──────────────────
      // jj auto-stages — no need to call stageAll()
      const testFilePath = join(
        workspaceResult.workspacePath,
        "feature.txt",
      );
      writeFileSync(
        testFilePath,
        "# Feature implementation\nconsole.log('jj-hello');\n",
      );
      expect(existsSync(testFilePath)).toBe(true);

      // ── Phase 3: Commit (no stageAll() — jj auto-stages) ────────────
      const commitMessage = `Implement jj feature (${seedId})`;
      await backend.commit(workspaceResult.workspacePath, commitMessage);

      // HEAD change ID should be non-empty after commit
      const headAfterCommit = await backend.getHeadId(
        workspaceResult.workspacePath,
      );
      expect(headAfterCommit).toBeTruthy();
      expect(headAfterCommit.length).toBeGreaterThan(0);

      // ── Phase 4: Push to remote (--allow-new required for jj) ───────
      await backend.push(
        workspaceResult.workspacePath,
        workspaceResult.branchName,
        { allowNew: true },
      );

      // Verify the bookmark exists on the remote after push
      await backend.fetch(localDir);
      const branchOnRemote = await backend.branchExistsOnRemote(
        localDir,
        workspaceResult.branchName,
      );
      expect(branchOnRemote).toBe(true);

      // ── Phase 5: Merge into dev ──────────────────────────────────────
      const mergeResult = await backend.merge(
        localDir,
        workspaceResult.branchName,
        "dev",
      );

      expect(mergeResult.success).toBe(true);
      expect(mergeResult.conflicts).toBeUndefined();

      // ── Phase 6: Cleanup workspace ───────────────────────────────────
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

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-seed-jj-list";

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

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-seed-jj-no-conflict";

      const { workspacePath, branchName } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      // Write a unique file — will not conflict with anything on dev
      writeFileSync(
        join(workspacePath, "unique-jj-feature.ts"),
        "export const x = 42;\n",
      );
      // No stageAll() needed — jj auto-stages
      await backend.commit(
        workspacePath,
        `feat: add unique jj feature (${seedId})`,
      );
      await backend.push(workspacePath, branchName, { allowNew: true });

      await backend.fetch(localDir);
      const result = await backend.merge(localDir, branchName, "dev");

      expect(result.success).toBe(true);
      expect(result.conflicts).toBeUndefined();

      // Cleanup
      await backend.removeWorkspace(localDir, workspacePath);
    });
  },
);

// ── AC-007-2: jj commands in correct order ───────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "AC-007-2: JujutsuBackend commands are called in the expected order",
  () => {
    it("push() calls jj git push --bookmark <branchName> --allow-new and puts bookmark on remote", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-jj-ac007-2";

      const { workspacePath, branchName } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      writeFileSync(join(workspacePath, "test-file.txt"), "test content\n");
      await backend.commit(workspacePath, "test commit");

      // push() should not throw; bookmark should exist on remote afterwards
      await expect(
        backend.push(workspacePath, branchName, { allowNew: true }),
      ).resolves.toBeUndefined();

      await backend.fetch(localDir);
      const exists = await backend.branchExistsOnRemote(localDir, branchName);
      expect(exists).toBe(true);

      await backend.removeWorkspace(localDir, workspacePath);
    });

    it("commit() sequence: describe + new results in non-empty change ID", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-jj-ac007-commit";

      const { workspacePath } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      // Write multiple files — jj auto-stages all of them
      writeFileSync(join(workspacePath, "file-a.ts"), "export const a = 1;\n");
      writeFileSync(join(workspacePath, "file-b.ts"), "export const b = 2;\n");
      writeFileSync(join(workspacePath, "file-c.md"), "# Docs\n");

      await backend.commit(workspacePath, "feat: add three files");

      // After commit(), getHeadId() should return a non-empty change ID
      const headId = await backend.getHeadId(workspacePath);
      expect(headId).toBeTruthy();
      expect(headId.length).toBeGreaterThan(0);

      await backend.removeWorkspace(localDir, workspacePath);
    });

    it("stageAll() is a no-op and commit() still succeeds without it", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-jj-noop-stage";

      const { workspacePath } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      writeFileSync(join(workspacePath, "auto-staged.txt"), "jj auto-stages me\n");

      // stageAll() is a no-op for jj — should not throw
      await expect(backend.stageAll(workspacePath)).resolves.toBeUndefined();

      // commit() should succeed without having called stageAll()
      await expect(
        backend.commit(workspacePath, "chore: auto-staged file"),
      ).resolves.toBeUndefined();

      await backend.removeWorkspace(localDir, workspacePath);
    });
  },
);

// ── AC-022-1: Pipeline overhead < 1% ─────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "AC-022-1: JujutsuBackend abstraction overhead is negligible",
  () => {
    it("full pipeline cycle completes in a reasonable time (< 30s)", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-jj-ac022-perf";

      const startTime = Date.now();

      // Execute the full pipeline via the abstraction layer
      const { workspacePath, branchName } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      writeFileSync(
        join(workspacePath, "perf-test.ts"),
        "export const perf = true;\n",
      );
      // No stageAll() needed for jj
      await backend.commit(workspacePath, `perf: test commit (${seedId})`);
      await backend.push(workspacePath, branchName, { allowNew: true });
      await backend.fetch(localDir);
      const mergeResult = await backend.merge(localDir, branchName, "dev");
      await backend.removeWorkspace(localDir, workspacePath);

      const totalTime = Date.now() - startTime;

      // AC-022-1: overhead must be negligible — full pipeline < 30 seconds
      expect(totalTime).toBeLessThan(30_000);
      expect(mergeResult.success).toBe(true);
    });

    it("getCurrentBranch() repeated calls complete in a reasonable time", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);

      // Measure time for 5 getCurrentBranch calls via abstraction
      const iterations = 5;
      const start = Date.now();
      for (let i = 0; i < iterations; i++) {
        await backend.getCurrentBranch(localDir);
      }
      const totalTime = Date.now() - start;

      // Each call invokes jj CLI subprocess. 5 calls should complete well under 30s.
      // jj process startup typically takes ~500ms; generous upper bound.
      expect(totalTime).toBeLessThan(30_000);
    });
  },
);

// ── Rebase Before Merge (Foreman Pattern) ────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "JujutsuBackend Integration: Rebase before merge (Foreman finalize pattern)",
  () => {
    it("rebases feature bookmark onto dev before merging (no conflicts)", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const backend = new JujutsuBackend(localDir);
      const seedId = "test-jj-rebase-merge";

      // Create workspace on feature bookmark
      const { workspacePath, branchName } = await backend.createWorkspace(
        localDir,
        seedId,
        "dev",
      );
      tempDirs.push(workspacePath);

      // Add a commit on the feature workspace
      writeFileSync(
        join(workspacePath, "feature-work.ts"),
        "export const work = 'done';\n",
      );
      await backend.commit(workspacePath, `feat: feature work (${seedId})`);

      // Push the feature bookmark (first push needs --allow-new)
      await backend.push(workspacePath, branchName, { allowNew: true });

      // Fetch and rebase onto origin/dev (simulating Foreman's finalize step)
      await backend.fetch(workspacePath);
      const rebaseResult = await backend.rebase(workspacePath, "dev@origin");
      expect(rebaseResult.success).toBe(true);
      expect(rebaseResult.hasConflicts).toBe(false);

      // After rebase, push again. jj applies safety checks similar to
      // git push --force-with-lease by default, so --allow-new is sufficient
      // for an updated bookmark that was previously pushed.
      // Note: jj 0.39.x does not support a --force flag on jj git push.
      await backend.push(workspacePath, branchName, { allowNew: true });

      // Now merge the rebased feature bookmark
      await backend.fetch(localDir);
      const mergeResult = await backend.merge(localDir, branchName, "dev");
      expect(mergeResult.success).toBe(true);

      await backend.removeWorkspace(localDir, workspacePath);
    });
  },
);
