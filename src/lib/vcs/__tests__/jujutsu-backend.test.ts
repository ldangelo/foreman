/**
 * Tests for JujutsuBackend.
 *
 * These tests verify the JujutsuBackend's interface compliance and
 * the getFinalizeCommands() output (which doesn't require jj to be installed).
 *
 * Tests that require the `jj` CLI are skipped when jj is not installed.
 */

import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { JujutsuBackend } from "../jujutsu-backend.js";

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

// ── Temp repo helpers ─────────────────────────────────────────────────────────

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

/**
 * Create a colocated jj+git temp repo and return its real path.
 * Uses `jj git init --colocate` to set up a jj repo on top of a git repo.
 */
function makeTempJjRepo(): string {
  // realpathSync resolves macOS /var → /private/var symlink
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-backend-test-")),
  );
  // Initialize a colocated jj+git repository
  execFileSync("git", ["init"], { cwd: dir, stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "test@test.com"], {
    cwd: dir,
    stdio: "pipe",
  });
  execFileSync("git", ["config", "user.name", "Test"], {
    cwd: dir,
    stdio: "pipe",
  });
  execFileSync("jj", ["git", "init", "--colocate"], {
    cwd: dir,
    stdio: "pipe",
  });
  return dir;
}

// ── Constructor ───────────────────────────────────────────────────────────────

describe("JujutsuBackend constructor", () => {
  it("sets name to 'jujutsu'", () => {
    const b = new JujutsuBackend('/tmp');
    expect(b.name).toBe('jujutsu');
  });

  it("stores projectPath", () => {
    const b = new JujutsuBackend('/custom/path');
    expect(b.projectPath).toBe('/custom/path');
  });
});

// ── stageAll (no-op) ──────────────────────────────────────────────────────────

describe("JujutsuBackend.stageAll", () => {
  it("is a no-op and does not throw", async () => {
    const b = new JujutsuBackend('/tmp');
    await expect(b.stageAll('/tmp')).resolves.toBeUndefined();
  });
});

// ── getFinalizeCommands ───────────────────────────────────────────────────────

describe("JujutsuBackend.getFinalizeCommands", () => {
  it("returns empty stageCommand (jj auto-stages)", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.stageCommand).toBe('');
  });

  it("returns jj describe command for commitCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.commitCommand).toContain('jj describe');
    expect(cmds.commitCommand).toContain('bd-test');
    expect(cmds.commitCommand).toContain('Test task');
    expect(cmds.commitCommand).toContain('jj new');
  });

  it("returns jj git push with --allow-new for pushCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.pushCommand).toContain('jj git push');
    expect(cmds.pushCommand).toContain('--allow-new');
    expect(cmds.pushCommand).toContain('foreman/bd-test');
  });

  it("returns jj rebase command with base branch for rebaseCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'dev',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.rebaseCommand).toContain('jj rebase');
    expect(cmds.rebaseCommand).toContain('dev');
  });

  it("returns jj workspace forget for cleanCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.cleanCommand).toContain('jj workspace forget');
    expect(cmds.cleanCommand).toContain('bd-test');
  });

  it("all 6 FinalizeCommands fields are present", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-abc',
      seedTitle: 'Some task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-abc',
    });
    expect(typeof cmds.stageCommand).toBe('string');
    expect(typeof cmds.commitCommand).toBe('string');
    expect(typeof cmds.pushCommand).toBe('string');
    expect(typeof cmds.rebaseCommand).toBe('string');
    expect(typeof cmds.branchVerifyCommand).toBe('string');
    expect(typeof cmds.cleanCommand).toBe('string');
  });

  it("branchVerifyCommand uses jj bookmark list", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-xyz',
      seedTitle: 'XYZ task',
      baseBranch: 'main',
      worktreePath: '/tmp',
    });
    expect(cmds.branchVerifyCommand).toContain('jj bookmark list');
    expect(cmds.branchVerifyCommand).toContain('bd-xyz');
  });
});

// ── Tests requiring jj ────────────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend (requires jj)", () => {
  it("jj is available", () => {
    expect(JJ_AVAILABLE).toBe(true);
  });
});

// ── AC-T-017-1: getRepoRoot() ─────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.getRepoRoot (AC-T-017-1)", () => {
  it("returns the repo root when called from the root itself", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const root = await backend.getRepoRoot(repo);
    expect(root).toBe(repo);
  });

  it("finds the repo root when called from a subdirectory", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const subdir = join(repo, "src", "nested");
    execFileSync("mkdir", ["-p", subdir]);
    const backend = new JujutsuBackend(repo);

    const root = await backend.getRepoRoot(subdir);
    expect(root).toBe(repo);
  });

  it("throws when the path is not inside a git/jj repository", async () => {
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-no-jj-")),
    );
    tempDirs.push(dir);
    const backend = new JujutsuBackend(dir);

    await expect(backend.getRepoRoot(dir)).rejects.toThrow(/rev-parse failed/);
  });
});

// ── AC-T-017-2: getCurrentBranch() ───────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "JujutsuBackend.getCurrentBranch (AC-T-017-2)",
  () => {
    it("returns a non-empty change ID when no bookmark is set on @", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);
      const backend = new JujutsuBackend(repo);

      const branch = await backend.getCurrentBranch(repo);
      // With no bookmark, jj falls back to the short change ID (12 alphanumeric chars)
      expect(branch).toBeTruthy();
      expect(branch.length).toBeGreaterThan(0);
    });

    it("returns the bookmark name when a bookmark is set on @", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);

      // Create a bookmark pointing to the current revision
      execFileSync("jj", ["bookmark", "create", "my-feature", "-r", "@"], {
        cwd: repo,
        stdio: "pipe",
      });
      const backend = new JujutsuBackend(repo);

      const branch = await backend.getCurrentBranch(repo);
      expect(branch).toBe("my-feature");
    });

    it("returns the first bookmark when multiple bookmarks are set on @", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);

      // Create two bookmarks pointing to the same revision
      execFileSync("jj", ["bookmark", "create", "alpha", "-r", "@"], {
        cwd: repo,
        stdio: "pipe",
      });
      execFileSync("jj", ["bookmark", "create", "beta", "-r", "@"], {
        cwd: repo,
        stdio: "pipe",
      });
      const backend = new JujutsuBackend(repo);

      const branch = await backend.getCurrentBranch(repo);
      // Should return one of the bookmark names (first in the list)
      expect(["alpha", "beta"]).toContain(branch);
    });
  },
);

// ── AC-T-017-2b: detectDefaultBranch() ───────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)(
  "JujutsuBackend.detectDefaultBranch (AC-T-017-2b)",
  () => {
    it("falls back to current branch when no main/master bookmark exists", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);
      const backend = new JujutsuBackend(repo);

      const defaultBranch = await backend.detectDefaultBranch(repo);
      // No main or master bookmark → falls back to getCurrentBranch
      expect(defaultBranch).toBeTruthy();
      expect(defaultBranch.length).toBeGreaterThan(0);
    });

    it("returns 'main' when a main bookmark exists", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);

      // Create (or update) the main bookmark pointing to @
      // Use `jj bookmark set` to handle the case where jj auto-imports
      // a 'main' bookmark from git
      execFileSync(
        "jj",
        ["bookmark", "set", "main", "--allow-backwards", "-r", "@"],
        { cwd: repo, stdio: "pipe" },
      );

      const backend = new JujutsuBackend(repo);
      const defaultBranch = await backend.detectDefaultBranch(repo);
      expect(defaultBranch).toBe("main");
    });
  },
);

// ── AC-T-017-3: Error handling ────────────────────────────────────────────────

describe("JujutsuBackend error handling (AC-T-017-3)", () => {
  it("getRepoRoot throws a formatted error outside a repository", async () => {
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-no-repo-")),
    );
    tempDirs.push(dir);
    const backend = new JujutsuBackend(dir);

    await expect(backend.getRepoRoot(dir)).rejects.toThrow(/failed/);
  });

  it("getCurrentBranch throws a formatted error outside a jj repository", async () => {
    // A plain dir with no jj repo — jj log will fail
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-no-repo-")),
    );
    tempDirs.push(dir);
    const backend = new JujutsuBackend(dir);

    await expect(backend.getCurrentBranch(dir)).rejects.toThrow(/jj log failed/);
  });

  it("detectDefaultBranch throws a formatted error outside a jj repository", async () => {
    // A plain dir with no jj repo — all jj calls fail, getCurrentBranch is the final fallback
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-no-repo-")),
    );
    tempDirs.push(dir);
    const backend = new JujutsuBackend(dir);

    await expect(backend.detectDefaultBranch(dir)).rejects.toThrow(/jj log failed/);
  });
});
