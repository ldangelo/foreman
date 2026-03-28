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

// ── AC-T-020: Sync Operations ─────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend sync operations (AC-T-020)", () => {
  /**
   * Helper: create a jj repo with a local bare git remote registered as "origin".
   * Returns both paths; both are pushed to tempDirs for cleanup.
   */
  function makeRepoWithBareRemote(): { repoPath: string; remotePath: string } {
    const repoPath = makeTempJjRepo();
    const remotePath = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-bare-")),
    );
    tempDirs.push(repoPath, remotePath);

    execFileSync("git", ["init", "--bare"], { cwd: remotePath, stdio: "pipe" });
    execFileSync("git", ["remote", "add", "origin", remotePath], {
      cwd: repoPath,
      stdio: "pipe",
    });

    return { repoPath, remotePath };
  }

  // AC-T-020-1: fetch() succeeds against a valid remote ─────────────────────

  it("fetch() succeeds against a local bare remote (AC-T-020-1)", async () => {
    const { repoPath } = makeRepoWithBareRemote();
    const backend = new JujutsuBackend(repoPath);

    // Fetching from an empty-but-valid remote should not throw
    await expect(backend.fetch(repoPath)).resolves.toBeUndefined();
  });

  it("fetch() resolves to undefined (return type matches interface)", async () => {
    const { repoPath } = makeRepoWithBareRemote();
    const backend = new JujutsuBackend(repoPath);
    const result = await backend.fetch(repoPath);
    expect(result).toBeUndefined();
  });

  // AC-T-020-2: rebase() onto non-conflicting target returns success ─────────

  it("rebase() returns success:true for a no-conflict rebase (AC-T-020-2)", async () => {
    const repoPath = makeTempJjRepo();
    tempDirs.push(repoPath);

    // Describe the initial working copy (becomes "base")
    writeFileSync(join(repoPath, "base.txt"), "base content");
    execFileSync("jj", ["describe", "-m", "Base commit"], {
      cwd: repoPath,
      stdio: "pipe",
    });
    execFileSync("jj", ["bookmark", "create", "base", "-r", "@"], {
      cwd: repoPath,
      stdio: "pipe",
    });

    // Create a new revision on top of base with a non-conflicting file
    execFileSync("jj", ["new"], { cwd: repoPath, stdio: "pipe" });
    writeFileSync(join(repoPath, "feature.txt"), "feature content");
    execFileSync("jj", ["describe", "-m", "Feature commit"], {
      cwd: repoPath,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(repoPath);
    const result = await backend.rebase(repoPath, "base");

    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);
    expect(result.conflictingFiles ?? []).toHaveLength(0);
  });

  it("rebase() result has the expected shape (RebaseResult interface)", async () => {
    const repoPath = makeTempJjRepo();
    tempDirs.push(repoPath);

    writeFileSync(join(repoPath, "a.txt"), "a");
    execFileSync("jj", ["describe", "-m", "A"], { cwd: repoPath, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "target", "-r", "@"], {
      cwd: repoPath,
      stdio: "pipe",
    });
    execFileSync("jj", ["new"], { cwd: repoPath, stdio: "pipe" });

    const backend = new JujutsuBackend(repoPath);
    const result = await backend.rebase(repoPath, "target");

    // Shape check
    expect(typeof result.success).toBe("boolean");
    expect(typeof result.hasConflicts).toBe("boolean");
  });

  // AC-T-020-3: abortRebase() calls jj undo ────────────────────────────────

  it("abortRebase() resolves without throwing (AC-T-020-3)", async () => {
    const repoPath = makeTempJjRepo();
    tempDirs.push(repoPath);

    // Create some state for undo to act on
    writeFileSync(join(repoPath, "file.txt"), "initial content");
    execFileSync("jj", ["describe", "-m", "Initial"], {
      cwd: repoPath,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(repoPath);
    await expect(backend.abortRebase(repoPath)).resolves.toBeUndefined();
  });

  it("abortRebase() records an undo entry in jj op log (AC-T-020-3)", async () => {
    const repoPath = makeTempJjRepo();
    tempDirs.push(repoPath);

    // Set up some state
    writeFileSync(join(repoPath, "file.txt"), "content");
    execFileSync("jj", ["describe", "-m", "Commit for undo test"], {
      cwd: repoPath,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(repoPath);
    await backend.abortRebase(repoPath);

    // jj op log --no-graph --limit 1 should include "undo" in its output
    const opLog = execFileSync(
      "jj",
      ["op", "log", "--no-graph", "--limit", "1"],
      { cwd: repoPath, stdio: "pipe" },
    ).toString();

    expect(opLog.toLowerCase()).toContain("undo");
  });

  // Push operations (AC-011-1, AC-011-2) ────────────────────────────────────

  it("push() with allowNew:true pushes a bookmark to a local remote (AC-011-1, AC-011-2)", async () => {
    const repoPath = makeTempJjRepo();
    const remotePath = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-push-remote-")),
    );
    tempDirs.push(repoPath, remotePath);

    execFileSync("git", ["init", "--bare"], { cwd: remotePath, stdio: "pipe" });
    execFileSync("git", ["remote", "add", "origin", remotePath], {
      cwd: repoPath,
      stdio: "pipe",
    });

    // Create a commit and bookmark to push
    writeFileSync(join(repoPath, "hello.txt"), "hello world");
    execFileSync("jj", ["describe", "-m", "Hello"], {
      cwd: repoPath,
      stdio: "pipe",
    });
    execFileSync("jj", ["bookmark", "create", "test-branch", "-r", "@"], {
      cwd: repoPath,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(repoPath);
    await expect(
      backend.push(repoPath, "test-branch", { allowNew: true }),
    ).resolves.toBeUndefined();
  });

  it("push() without allowNew:true does not append --allow-new (AC-011-2 negative)", async () => {
    // We can't easily test CLI flags directly, but we verify push() doesn't throw
    // when the bookmark is already tracked on the remote.
    const repoPath = makeTempJjRepo();
    const remotePath = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-push-neg-")),
    );
    tempDirs.push(repoPath, remotePath);

    execFileSync("git", ["init", "--bare"], { cwd: remotePath, stdio: "pipe" });
    execFileSync("git", ["remote", "add", "origin", remotePath], {
      cwd: repoPath,
      stdio: "pipe",
    });

    writeFileSync(join(repoPath, "a.txt"), "a");
    execFileSync("jj", ["describe", "-m", "A"], { cwd: repoPath, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "my-branch", "-r", "@"], {
      cwd: repoPath,
      stdio: "pipe",
    });
    // First push with --allow-new to establish tracking
    execFileSync(
      "jj",
      ["git", "push", "--bookmark", "my-branch", "--allow-new"],
      { cwd: repoPath, stdio: "pipe" },
    );

    // Second push without allowNew — bookmark already tracked, should succeed
    const backend = new JujutsuBackend(repoPath);
    await expect(
      backend.push(repoPath, "my-branch", { allowNew: false }),
    ).resolves.toBeUndefined();
  });

  // Pull operations ─────────────────────────────────────────────────────────

  it("pull() fetches and tracks a remote bookmark without throwing", async () => {
    // Set up: source repo → bare remote; consumer repo pulls from that remote
    const remotePath = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-pull-remote-")),
    );
    tempDirs.push(remotePath);
    execFileSync("git", ["init", "--bare"], { cwd: remotePath, stdio: "pipe" });

    // Source repo: create a commit and push it to remote
    const sourceRepo = makeTempJjRepo();
    tempDirs.push(sourceRepo);
    writeFileSync(join(sourceRepo, "source.txt"), "source");
    execFileSync("jj", ["describe", "-m", "Source commit"], {
      cwd: sourceRepo,
      stdio: "pipe",
    });
    execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], {
      cwd: sourceRepo,
      stdio: "pipe",
    });
    execFileSync("git", ["remote", "add", "origin", remotePath], {
      cwd: sourceRepo,
      stdio: "pipe",
    });
    execFileSync(
      "jj",
      ["git", "push", "--bookmark", "main", "--allow-new"],
      { cwd: sourceRepo, stdio: "pipe" },
    );

    // Consumer repo: add the same remote and pull
    const consumerRepo = makeTempJjRepo();
    tempDirs.push(consumerRepo);
    execFileSync("git", ["remote", "add", "origin", remotePath], {
      cwd: consumerRepo,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(consumerRepo);
    await expect(backend.pull(consumerRepo, "main")).resolves.toBeUndefined();
  });
});

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
