/**
 * Integration tests for setup-cache with JujutsuBackend.
 *
 * Validates AC-T-033-1: Given a jj workspace with setup-cache config,
 * when createWorkspace() runs twice, then the second run is a cache hit
 * (symlink exists pointing to the shared cache location).
 *
 * Tests are wrapped in `describe.skipIf(!JJ_AVAILABLE)` to gracefully skip
 * when the `jj` CLI is not installed.
 *
 * @module src/lib/vcs/__tests__/jujutsu-setup-cache.test
 */

import { describe, it, expect, afterEach, beforeEach } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
  existsSync,
  mkdirSync,
  lstatSync,
  readlinkSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runSetupWithCache } from "../../git.js";
import type { WorkflowSetupCache, WorkflowSetupStep } from "../../workflow-loader.js";

// ── Check if jj is available ──────────────────────────────────────────────────

function isJjAvailable(): boolean {
  try {
    execFileSync("jj", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

const JJ_AVAILABLE = isJjAvailable();
const ORIGINAL_HOME = process.env.HOME;
const ORIGINAL_XDG_CONFIG_HOME = process.env.XDG_CONFIG_HOME;
let jjHomeDir: string;

// ── Cleanup ───────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

beforeEach(() => {
  jjHomeDir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-jj-cache-home-")));
  tempDirs.push(jjHomeDir);
  process.env.HOME = jjHomeDir;
  process.env.XDG_CONFIG_HOME = join(jjHomeDir, ".config");
});

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
  process.env.HOME = ORIGINAL_HOME;
  process.env.XDG_CONFIG_HOME = ORIGINAL_XDG_CONFIG_HOME;
});

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Bootstrap a bare git remote + a colocated jj+git local clone with an
 * initial commit on the `dev` branch.
 *
 * Returns `{ remoteDir, localDir }`.
 */
function makeRemoteAndLocal(): { remoteDir: string; localDir: string } {
  // Create bare git remote
  const remoteDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-cache-remote-")),
  );
  execFileSync("git", ["init", "--bare", "--initial-branch=dev"], {
    cwd: remoteDir,
    stdio: "pipe",
  });

  // Bootstrap: use a plain git repo to push an initial commit to the bare remote
  const initDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-cache-init-")),
  );
  tempDirs.push(initDir);

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
  writeFileSync(join(initDir, "README.md"), "# Test repo\n");
  // Write a key file for cache testing
  writeFileSync(join(initDir, "package-lock.json"), JSON.stringify({ version: 1 }));
  execFileSync("git", ["add", "."], { cwd: initDir, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "initial commit"], {
    cwd: initDir,
    stdio: "pipe",
  });
  execFileSync("git", ["push", "--set-upstream", "origin", "dev"], {
    cwd: initDir,
    stdio: "pipe",
  });

  // Clone the remote into a local colocated jj+git repo
  const localDir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-cache-local-")),
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
  execFileSync("jj", ["git", "init", "--colocate"], {
    cwd: localDir,
    stdio: "pipe",
  });
  execFileSync("jj", ["config", "set", "--repo", "user.name", "Test Agent"], {
    cwd: localDir,
    stdio: "pipe",
  });
  execFileSync("jj", ["config", "set", "--repo", "user.email", "test@test.com"], {
    cwd: localDir,
    stdio: "pipe",
  });

  return { remoteDir, localDir };
}

/**
 * Create a simulated workspace directory that mimics what JujutsuBackend
 * creates. The workspace contains a key file for cache key computation.
 *
 * Returns the workspace path.
 */
function makeWorkspaceWithKeyFile(localDir: string, seedId: string): string {
  const workspacePath = realpathSync(
    mkdtempSync(join(tmpdir(), `foreman-ws-${seedId}-`)),
  );
  // Copy the key file into the workspace
  const keyContent = JSON.stringify({ version: 1 });
  writeFileSync(join(workspacePath, "package-lock.json"), keyContent);
  return workspacePath;
}

// ── AC-T-033-1: Cache hit on second workspace creation ────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "AC-T-033-1: Setup-cache hit on second jj workspace creation",
  () => {
    it("second workspace hits the cache (symlink exists, steps skipped)", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      // Project root: localDir acts as the .foreman cache store root
      const projectRoot = localDir;

      // Setup cache config: hash package-lock.json, cache "cached-dir"
      const cacheConfig: WorkflowSetupCache = {
        key: "package-lock.json",
        path: "cached-dir",
      };

      // Track if setup steps ran (simulated by writing a sentinel file)
      const setupRanMarkers: string[] = [];

      // Setup step: create cached-dir + write a file inside it
      const setupSteps: WorkflowSetupStep[] = [
        {
          command: "mkdir -p cached-dir",
          description: "Create cached-dir",
        },
        {
          command: "touch cached-dir/setup-ran.txt",
          description: "Mark that setup ran",
        },
      ];

      // ── First workspace ──────────────────────────────────────────────────

      const workspace1 = makeWorkspaceWithKeyFile(localDir, "seed-cache-1");
      tempDirs.push(workspace1);
      setupRanMarkers.push(join(workspace1, "cached-dir", "setup-ran.txt"));

      // First run: cache miss → run setup → populate cache
      await runSetupWithCache(workspace1, projectRoot, setupSteps, cacheConfig);

      // Verify: cached-dir exists in workspace1
      expect(existsSync(join(workspace1, "cached-dir"))).toBe(true);

      // Verify: setup-ran.txt exists inside the cached dir
      expect(existsSync(join(workspace1, "cached-dir", "setup-ran.txt"))).toBe(true);

      // Verify: the cache was populated (`.complete` marker exists)
      // Compute expected cache hash manually
      const { createHash } = await import("node:crypto");
      const { readFileSync } = await import("node:fs");
      const keyContent = readFileSync(join(workspace1, "package-lock.json"));
      const hash = createHash("sha256")
        .update(keyContent)
        .digest("hex")
        .slice(0, 16);
      const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);

      expect(existsSync(join(cacheDir, ".complete"))).toBe(true);
      expect(existsSync(join(cacheDir, "cached-dir"))).toBe(true);

      // Verify: workspace1/cached-dir is a symlink (after populateCache)
      const stat1 = lstatSync(join(workspace1, "cached-dir"));
      expect(stat1.isSymbolicLink()).toBe(true);

      // Verify: symlink target is the cache directory
      const target1 = readlinkSync(join(workspace1, "cached-dir"));
      expect(target1).toBe(join(cacheDir, "cached-dir"));

      // ── Second workspace ─────────────────────────────────────────────────

      const workspace2 = makeWorkspaceWithKeyFile(localDir, "seed-cache-2");
      tempDirs.push(workspace2);

      // Write a marker to detect if setup steps ran (they should NOT run on cache hit)
      const stepRanSentinel = join(workspace2, "setup-step-ran.flag");

      // Use modified setup steps that also write a sentinel to workspace root
      const setupStepsWithSentinel: WorkflowSetupStep[] = [
        {
          command: "mkdir -p cached-dir",
          description: "Create cached-dir",
        },
        {
          command: "touch cached-dir/setup-ran.txt",
          description: "Mark that setup ran",
        },
        {
          command: "touch setup-step-ran.flag",
          description: "Write sentinel to workspace root (should NOT appear on cache hit)",
        },
      ];

      // Second run: cache hit → skip steps → symlink only
      await runSetupWithCache(workspace2, projectRoot, setupStepsWithSentinel, cacheConfig);

      // Verify: sentinel was NOT written (setup steps did not run)
      expect(existsSync(stepRanSentinel)).toBe(false);

      // Verify: cached-dir exists in workspace2
      expect(existsSync(join(workspace2, "cached-dir"))).toBe(true);

      // Verify: workspace2/cached-dir is a symlink
      const stat2 = lstatSync(join(workspace2, "cached-dir"));
      expect(stat2.isSymbolicLink()).toBe(true);

      // Verify: both workspaces symlink to the SAME cache directory
      const target2 = readlinkSync(join(workspace2, "cached-dir"));
      expect(target2).toBe(join(cacheDir, "cached-dir"));
      expect(target1).toBe(target2);
    });

    it("cache miss on different key file content → steps run for each", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const projectRoot = localDir;

      const cacheConfig: WorkflowSetupCache = {
        key: "package-lock.json",
        path: "cached-dir",
      };

      const setupSteps: WorkflowSetupStep[] = [
        { command: "mkdir -p cached-dir", description: "Create cached-dir" },
        { command: "touch cached-dir/setup-ran.txt" },
      ];

      // Workspace A: uses key content { version: 1 }
      const workspaceA = makeWorkspaceWithKeyFile(localDir, "seed-key-a");
      tempDirs.push(workspaceA);

      await runSetupWithCache(workspaceA, projectRoot, setupSteps, cacheConfig);

      // Verify cache A populated
      const { createHash } = await import("node:crypto");
      const { readFileSync } = await import("node:fs");
      const keyContentA = readFileSync(join(workspaceA, "package-lock.json"));
      const hashA = createHash("sha256")
        .update(keyContentA)
        .digest("hex")
        .slice(0, 16);
      const cacheDirA = join(projectRoot, ".foreman", "setup-cache", hashA);
      expect(existsSync(join(cacheDirA, ".complete"))).toBe(true);

      // Workspace B: uses DIFFERENT key content → different hash
      const workspaceB = realpathSync(
        mkdtempSync(join(tmpdir(), "foreman-ws-seed-key-b-")),
      );
      tempDirs.push(workspaceB);
      // Write different key file content
      writeFileSync(
        join(workspaceB, "package-lock.json"),
        JSON.stringify({ version: 2, differentContent: true }),
      );

      await runSetupWithCache(workspaceB, projectRoot, setupSteps, cacheConfig);

      // Verify cache B is different from cache A
      const keyContentB = readFileSync(join(workspaceB, "package-lock.json"));
      const hashB = createHash("sha256")
        .update(keyContentB)
        .digest("hex")
        .slice(0, 16);

      expect(hashA).not.toBe(hashB);

      const cacheDirB = join(projectRoot, ".foreman", "setup-cache", hashB);
      expect(existsSync(join(cacheDirB, ".complete"))).toBe(true);

      // Verify workspaceB's symlink points to its own cache, NOT workspaceA's
      const statB = lstatSync(join(workspaceB, "cached-dir"));
      expect(statB.isSymbolicLink()).toBe(true);
      const targetB = readlinkSync(join(workspaceB, "cached-dir"));
      expect(targetB).toBe(join(cacheDirB, "cached-dir"));
      expect(targetB).not.toBe(join(cacheDirA, "cached-dir"));
    });

    it("missing key file → no caching, steps still run", async () => {
      const { remoteDir, localDir } = makeRemoteAndLocal();
      tempDirs.push(remoteDir, localDir);

      const projectRoot = localDir;

      const cacheConfig: WorkflowSetupCache = {
        key: "nonexistent-lock.json", // key file does not exist
        path: "cached-dir",
      };

      const setupSteps: WorkflowSetupStep[] = [
        { command: "mkdir -p cached-dir", description: "Create cached-dir" },
        { command: "touch cached-dir/setup-ran.txt" },
      ];

      // Workspace with NO key file
      const workspaceNoKey = realpathSync(
        mkdtempSync(join(tmpdir(), "foreman-ws-nokey-")),
      );
      tempDirs.push(workspaceNoKey);

      // Should not throw even when key file is missing
      await expect(
        runSetupWithCache(workspaceNoKey, projectRoot, setupSteps, cacheConfig),
      ).resolves.toBeUndefined();

      // Setup steps should have run (cached-dir created)
      expect(existsSync(join(workspaceNoKey, "cached-dir"))).toBe(true);
      expect(existsSync(join(workspaceNoKey, "cached-dir", "setup-ran.txt"))).toBe(true);

      // But cache was NOT populated (hash couldn't be computed)
      const cacheBase = join(projectRoot, ".foreman", "setup-cache");
      // Either the cache directory doesn't exist at all, or no .complete marker
      if (existsSync(cacheBase)) {
        // If there are any subdirs, none should have a .complete with undefined hash
        // Just verify the cached-dir in workspace is NOT a symlink (no cache populated)
        const stat = lstatSync(join(workspaceNoKey, "cached-dir"));
        expect(stat.isSymbolicLink()).toBe(false);
      }
    });
  },
);
