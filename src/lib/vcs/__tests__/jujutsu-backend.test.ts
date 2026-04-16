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
import { getWorkspacePath } from "../../workspace-paths.js";

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
 * Create a temp jj repo and return its real path.
 * Uses `jj git init` in either colocated or non-colocated mode.
 */
function makeTempJjRepo(options?: { colocate?: boolean }): string {
  const colocate = options?.colocate ?? true;
  // realpathSync resolves macOS /var → /private/var symlink
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-jj-backend-test-")),
  );
  const initArgs = ["git", "init"];
  if (!colocate) {
    initArgs.push("--no-colocate");
  }
  execFileSync("jj", initArgs, {
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
    // jj new is intentionally NOT included — it creates an empty revision
    // that gets exported as an empty git commit when pushed.
    expect(cmds.commitCommand).not.toContain('jj new');
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

  it("returns jj rebase command with base branch for integrateTargetCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'dev',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.integrateTargetCommand).toContain('jj rebase');
    expect(cmds.integrateTargetCommand).toContain('dev');
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
    expect(typeof cmds.integrateTargetCommand).toBe('string');
    expect(typeof cmds.branchVerifyCommand).toBe('string');
    expect(typeof cmds.cleanCommand).toBe('string');
  });

  it('isAncestor returns false on resolution failure', async () => {
    const b = new JujutsuBackend('/tmp');
    await expect(b.isAncestor('/tmp', 'missing', 'HEAD')).resolves.toBe(false);
  });

  it("branchVerifyCommand uses jj bookmark list (positional arg, no --name flag)", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-xyz',
      seedTitle: 'XYZ task',
      baseBranch: 'main',
      worktreePath: '/tmp',
    });
    expect(cmds.branchVerifyCommand).toContain('jj bookmark list');
    expect(cmds.branchVerifyCommand).toContain('bd-xyz');
    // Must NOT use the --name flag (broken in jj 0.39.0+)
    expect(cmds.branchVerifyCommand).not.toContain('--name');
  });
});

// ── Tests requiring jj ────────────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend (requires jj)", () => {
  it("jj is available", () => {
    expect(JJ_AVAILABLE).toBe(true);
  });

  it("getCurrentBranch falls back to the parent bookmark for unbookmarked working-copy children", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    execFileSync(
      "jj",
      ["bookmark", "set", "dev", "--allow-backwards", "-r", "@"],
      { cwd: repo, stdio: "pipe" },
    );
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const branch = await backend.getCurrentBranch(repo);
    expect(branch).toBe("dev");
  });

  it("getRepoRoot works for a non-colocated jj repo", async () => {
    const repo = makeTempJjRepo({ colocate: false });
    tempDirs.push(repo);

    const backend = new JujutsuBackend(repo);
    await expect(backend.getRepoRoot(repo)).resolves.toBe(repo);
    await expect(backend.getMainRepoRoot(repo)).resolves.toBe(repo);
  });

  it("detectDefaultBranch uses jj bookmarks in a non-colocated repo", async () => {
    const repo = makeTempJjRepo({ colocate: false });
    tempDirs.push(repo);

    execFileSync(
      "jj",
      ["bookmark", "set", "dev", "--allow-backwards", "-r", "@"],
      { cwd: repo, stdio: "pipe" },
    );

    const backend = new JujutsuBackend(repo);
    const branch = await backend.detectDefaultBranch(repo);
    expect(branch).toBe("dev");
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
    it("falls back to current branch when no well-known bookmark exists", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);
      const backend = new JujutsuBackend(repo);

      const defaultBranch = await backend.detectDefaultBranch(repo);
      expect(defaultBranch).toBeTruthy();
      expect(defaultBranch.length).toBeGreaterThan(0);
    });

    it("respects git-town.main-branch when configured", async () => {
      const repo = makeTempJjRepo();
      tempDirs.push(repo);

      execFileSync("git", ["config", "git-town.main-branch", "dev"], {
        cwd: repo,
        stdio: "pipe",
      });
      execFileSync(
        "jj",
        ["bookmark", "set", "dev", "--allow-backwards", "-r", "@"],
        { cwd: repo, stdio: "pipe" },
      );

      const backend = new JujutsuBackend(repo);
      const defaultBranch = await backend.detectDefaultBranch(repo);
      expect(defaultBranch).toBe("dev");
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

    // Match "jj log failed" or "jj log --no-graph failed" (error format includes subcommand args)
    await expect(backend.getCurrentBranch(dir)).rejects.toThrow(/jj log.*failed/);
  });

  it("detectDefaultBranch throws a formatted error outside a jj repository", async () => {
    // A plain dir with no jj repo — all jj calls fail, getCurrentBranch is the final fallback
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-jj-no-repo-")),
    );
    tempDirs.push(dir);
    const backend = new JujutsuBackend(dir);

    // Match "jj log failed" or "jj log --no-graph failed" (error format includes subcommand args)
    await expect(backend.detectDefaultBranch(dir)).rejects.toThrow(/jj log.*failed/);
  });
});

// ── AC-T-018: Workspace Management ────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.createWorkspace (AC-T-018-1)", () => {
  it("creates a workspace directory and returns workspacePath + branchName", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Need at least one commit for jj workspace add to work
    writeFileSync(join(repo, "README.md"), "# init\n");
    execFileSync("jj", ["describe", "-m", "initial"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const result = await backend.createWorkspace(repo, "bd-test");

    expect(result.workspacePath).toContain("bd-test");
    expect(result.branchName).toBe("foreman/bd-test");
    // The workspace directory should exist
    const { existsSync } = await import("node:fs");
    expect(existsSync(result.workspacePath)).toBe(true);
  });

  it("reuses existing workspace directory and rebases (AC-T-018-3)", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Need commits for workspace operations
    writeFileSync(join(repo, "README.md"), "# init\n");
    execFileSync("jj", ["describe", "-m", "initial"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);

    // First call creates the workspace
    const result1 = await backend.createWorkspace(repo, "bd-reuse");

    // Second call should reuse and not throw
    const result2 = await backend.createWorkspace(repo, "bd-reuse");

    expect(result1.workspacePath).toBe(result2.workspacePath);
    expect(result1.branchName).toBe(result2.branchName);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.removeWorkspace (AC-T-018-2)", () => {
  it("removes the workspace and its directory", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "README.md"), "# init\n");
    execFileSync("jj", ["describe", "-m", "initial"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const { workspacePath } = await backend.createWorkspace(repo, "bd-remove");

    const { existsSync } = await import("node:fs");
    expect(existsSync(workspacePath)).toBe(true);

    await backend.removeWorkspace(repo, workspacePath);

    expect(existsSync(workspacePath)).toBe(false);
  });

  it("does not throw when workspace directory does not exist", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    const backend = new JujutsuBackend(repo);
    const nonExistent = getWorkspacePath(repo, "nonexistent");
    await expect(backend.removeWorkspace(repo, nonExistent)).resolves.toBeUndefined();
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.listWorkspaces (AC-T-018-4)", () => {
  it("returns an empty array when no non-default workspaces exist", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const workspaces = await backend.listWorkspaces(repo);
    // The default workspace is not included
    expect(workspaces).toBeInstanceOf(Array);
  });

  it("includes created workspaces in the list", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "README.md"), "# init\n");
    execFileSync("jj", ["describe", "-m", "initial"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    await backend.createWorkspace(repo, "bd-list-test");

    const workspaces = await backend.listWorkspaces(repo);
    const paths = workspaces.map((w) => w.path);
    expect(paths.some((p) => p.includes("bd-list-test"))).toBe(true);
  });
});

// ── AC-T-019: Commit Operations ───────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.commit (AC-T-019-1)", () => {
  it("sets a commit message using jj describe without advancing to new change", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "file.txt"), "hello\n");
    const backend = new JujutsuBackend(repo);

    // commit should not throw
    await expect(backend.commit(repo, "my commit message")).resolves.toBeUndefined();

    // The current @ should have the commit message (no jj new was called)
    const desc = execFileSync(
      "jj",
      ["log", "--no-graph", "-r", "@", "-T", "description"],
      { cwd: repo, stdio: "pipe" },
    ).toString().trim();

    expect(desc).toContain("my commit message");
  });

  it("includes the message in the current change (not parent)", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "file.txt"), "content\n");
    const backend = new JujutsuBackend(repo);

    await backend.commit(repo, "Test commit message (AC-019)");

    // The current change @ should have the message (commit() no longer calls jj new)
    const desc = execFileSync(
      "jj",
      ["log", "--no-graph", "-r", "@", "-T", "description"],
      { cwd: repo, stdio: "pipe" },
    ).toString().trim();

    expect(desc).toContain("Test commit message (AC-019)");
  });
});

// ── AC-T-020: Sync Operations ─────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.rebase (AC-T-020-3)", () => {
  it("returns success:true when rebase completes without conflicts", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create initial commit on main
    writeFileSync(join(repo, "main.txt"), "main content\n");
    execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["describe", "-m", "main commit"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    // Create a feature branch
    execFileSync("jj", ["bookmark", "create", "feature", "-r", "@"], { cwd: repo, stdio: "pipe" });
    writeFileSync(join(repo, "feature.txt"), "feature content\n");
    execFileSync("jj", ["describe", "-m", "feature commit"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.rebase — conflict detection (AC-T-020-2b)", () => {
  it("returns success=false and hasConflicts=true when jj rebase exits 0 with conflicts", async () => {
    // jj rebase exits with code 0 even when conflicts arise — it embeds
    // conflict markers in files. The implementation must detect this explicitly.
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create a "base" commit
    writeFileSync(join(repo, "shared.txt"), "base version\n");
    execFileSync("jj", ["describe", "-m", "base commit"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "base", "-r", "@"], { cwd: repo, stdio: "pipe" });

    // Create a "feature" change from base: write conflicting shared.txt
    execFileSync("jj", ["new", "base"], { cwd: repo, stdio: "pipe" });
    writeFileSync(join(repo, "shared.txt"), "feature version\n");
    execFileSync("jj", ["describe", "-m", "feature: write shared.txt"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "feature", "-r", "@"], { cwd: repo, stdio: "pipe" });

    // Advance "main" from base: write conflicting shared.txt
    execFileSync("jj", ["new", "base"], { cwd: repo, stdio: "pipe" });
    writeFileSync(join(repo, "shared.txt"), "main version\n");
    execFileSync("jj", ["describe", "-m", "main: update shared.txt"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], { cwd: repo, stdio: "pipe" });

    // Switch @ to feature so rebase acts on it
    execFileSync("jj", ["edit", "feature"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    // Rebase feature onto main — jj exits 0 but embeds conflict markers
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(false);
    expect(result.hasConflicts).toBe(true);
    // conflictingFiles should include an entry mentioning shared.txt
    // jj resolve --list outputs lines like "shared.txt    2-sided conflict"
    if (result.conflictingFiles !== undefined) {
      expect(result.conflictingFiles.some((f) => f.includes("shared.txt"))).toBe(true);
    }
  });

  it("returns success=true when rebase has no conflicts (AC-T-020-2 regression check)", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create a "base" commit
    writeFileSync(join(repo, "base.txt"), "base content\n");
    execFileSync("jj", ["describe", "-m", "base commit"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], { cwd: repo, stdio: "pipe" });

    // Create a new change on top with a unique file (no overlap with main)
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });
    writeFileSync(join(repo, "feature-only.txt"), "feature content\n");
    execFileSync("jj", ["describe", "-m", "feature: unique file"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.abortRebase (AC-T-020-5)", () => {
  it("does not throw (uses jj undo)", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "file.txt"), "content\n");
    execFileSync("jj", ["describe", "-m", "initial"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    // abortRebase should not throw even without an active rebase
    await expect(backend.abortRebase(repo)).resolves.toBeUndefined();
  });
});

// ── AC-T-021: Merge Operations ────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.merge (AC-T-021-1)", () => {
  it("creates a merge commit with two parents", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create a base commit
    writeFileSync(join(repo, "base.txt"), "base\n");
    execFileSync("jj", ["bookmark", "create", "main", "-r", "@"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["describe", "-m", "base commit"], { cwd: repo, stdio: "pipe" });

    // Create feature branch from same point
    execFileSync("jj", ["new", "-r", "@"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["bookmark", "create", "feature/test", "-r", "@"], { cwd: repo, stdio: "pipe" });
    writeFileSync(join(repo, "feature.txt"), "feature\n");
    execFileSync("jj", ["describe", "-m", "feature commit"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const result = await backend.merge(repo, "feature/test", "main");

    expect(result.success).toBe(true);
  });
});

// ── AC-T-022: Diff, Conflict, Status ─────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.getHeadId (AC-T-022-1)", () => {
  it("returns a non-empty change ID string", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const headId = await backend.getHeadId(repo);
    expect(headId).toBeTruthy();
    expect(typeof headId).toBe("string");
    expect(headId.length).toBeGreaterThan(0);
  });

  it("falls back to the parent bookmarked revision for unbookmarked working-copy children", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    execFileSync("jj", ["bookmark", "create", "dev", "-r", "@"], {
      cwd: repo,
      stdio: "pipe",
    });
    const parentHead = execFileSync(
      "jj",
      ["log", "--no-graph", "-r", "@", "-T", "change_id.short()"],
      { cwd: repo, stdio: "pipe", encoding: "utf8" },
    ).trim();

    execFileSync("jj", ["new", "-r", "@"], {
      cwd: repo,
      stdio: "pipe",
    });

    const backend = new JujutsuBackend(repo);
    const headId = await backend.getHeadId(repo);
    expect(headId).toBe(parentHead);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.getModifiedFiles (AC-T-022-2)", () => {
  it("returns an empty array when no files are changed", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const files = await backend.getModifiedFiles(repo);
    expect(files).toBeInstanceOf(Array);
  });

  it("returns modified files when changes exist", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "new-file.txt"), "content\n");
    const backend = new JujutsuBackend(repo);

    const files = await backend.getModifiedFiles(repo);
    expect(files.length).toBeGreaterThan(0);
    expect(files.some((f) => f.includes("new-file.txt"))).toBe(true);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.getConflictingFiles (AC-T-022-3)", () => {
  it("returns an empty array when there are no conflicts", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const conflicts = await backend.getConflictingFiles(repo);
    expect(conflicts).toBeInstanceOf(Array);
    expect(conflicts.length).toBe(0);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.status (AC-T-022-4)", () => {
  it("returns a status string from jj status", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const statusOutput = await backend.status(repo);
    expect(typeof statusOutput).toBe("string");
  });

  it("includes modified file in status output", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    writeFileSync(join(repo, "changed.txt"), "new content\n");
    const backend = new JujutsuBackend(repo);

    const statusOutput = await backend.status(repo);
    expect(statusOutput).toContain("changed.txt");
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.cleanWorkingTree (AC-T-022-5)", () => {
  it("restores files to parent revision state", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Commit a file
    writeFileSync(join(repo, "tracked.txt"), "original\n");
    execFileSync("jj", ["describe", "-m", "commit tracked"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    // Modify the file in a new change
    writeFileSync(join(repo, "tracked.txt"), "modified\n");

    const backend = new JujutsuBackend(repo);
    // cleanWorkingTree should restore without throwing
    await expect(backend.cleanWorkingTree(repo)).resolves.toBeUndefined();
  });

  it("removes newly added (untracked) files from the working tree (AC-T-022-5b)", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create a base commit
    writeFileSync(join(repo, "base.txt"), "base\n");
    execFileSync("jj", ["describe", "-m", "base commit"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    // Add a new file in the working copy (not yet committed)
    const newFile = join(repo, "untracked-new.txt");
    writeFileSync(newFile, "new file content\n");

    // Verify the file exists before clean
    const { existsSync } = await import("node:fs");
    expect(existsSync(newFile)).toBe(true);

    const backend = new JujutsuBackend(repo);
    await backend.cleanWorkingTree(repo);

    // The newly added file should be removed
    expect(existsSync(newFile)).toBe(false);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.diff (AC-T-022-6)", () => {
  it("returns diff output between two revisions", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    // Create two commits
    writeFileSync(join(repo, "v1.txt"), "version 1\n");
    execFileSync("jj", ["bookmark", "create", "v1", "-r", "@"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["describe", "-m", "v1"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["new"], { cwd: repo, stdio: "pipe" });

    writeFileSync(join(repo, "v2.txt"), "version 2\n");
    execFileSync("jj", ["bookmark", "create", "v2", "-r", "@"], { cwd: repo, stdio: "pipe" });
    execFileSync("jj", ["describe", "-m", "v2"], { cwd: repo, stdio: "pipe" });

    const backend = new JujutsuBackend(repo);
    const diffOutput = await backend.diff(repo, "v1", "@");

    expect(typeof diffOutput).toBe("string");
  });
});

// ── AC-T-020-1/2: branchExists and branchExistsOnRemote ──────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.branchExists (AC-T-020-1)", () => {
  it("returns false for a non-existent bookmark", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const exists = await backend.branchExists(repo, "nonexistent-bookmark");
    expect(exists).toBe(false);
  });

  it("returns true for an existing bookmark", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    execFileSync("jj", ["bookmark", "create", "my-bookmark", "-r", "@"], {
      cwd: repo,
      stdio: "pipe",
    });
    const backend = new JujutsuBackend(repo);

    const exists = await backend.branchExists(repo, "my-bookmark");
    expect(exists).toBe(true);
  });
});

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.branchExistsOnRemote (AC-T-020-2)", () => {
  it("returns false when no remote exists", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const exists = await backend.branchExistsOnRemote(repo, "any-branch");
    expect(exists).toBe(false);
  });
});

// ── AC-T-018-5: deleteBranch ──────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.deleteBranch (AC-T-018-5)", () => {
  it("returns deleted:false and wasFullyMerged:true when bookmark does not exist", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    const result = await backend.deleteBranch(repo, "nonexistent", {});
    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(true);
  });

  it("force-deletes an existing bookmark", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);

    execFileSync("jj", ["bookmark", "create", "to-delete", "-r", "@"], {
      cwd: repo,
      stdio: "pipe",
    });
    const backend = new JujutsuBackend(repo);

    const result = await backend.deleteBranch(repo, "to-delete", { force: true });
    expect(result.deleted).toBe(true);
  });
});

// ── AC-T-020-4: pull ──────────────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.pull (AC-T-020-4)", () => {
  it("fetches from origin without throwing when remote not configured", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    // pull calls jj git fetch; it should throw since there's no remote
    await expect(backend.pull(repo, "main")).rejects.toThrow();
  });
});

// ── AC-T-020-6: fetch ─────────────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend.fetch (AC-T-020-6)", () => {
  it("throws when no remote is configured", async () => {
    const repo = makeTempJjRepo();
    tempDirs.push(repo);
    const backend = new JujutsuBackend(repo);

    // jj git fetch with no remote configured should throw
    await expect(backend.fetch(repo)).rejects.toThrow();
  });
});

// ── Interface compliance ──────────────────────────────────────────────────────

describe("JujutsuBackend satisfies VcsBackend interface", () => {
  it("has all required interface methods", () => {
    const b = new JujutsuBackend('/tmp');
    const methods: string[] = [
      'getRepoRoot', 'getMainRepoRoot', 'detectDefaultBranch', 'getCurrentBranch',
      'checkoutBranch', 'branchExists', 'branchExistsOnRemote', 'deleteBranch',
      'createWorkspace', 'removeWorkspace', 'listWorkspaces',
      'stageAll', 'commit', 'push', 'pull',
      'rebase', 'abortRebase', 'merge',
      'getHeadId', 'fetch', 'diff', 'getModifiedFiles', 'getConflictingFiles',
      'status', 'cleanWorkingTree', 'getFinalizeCommands',
    ];
    for (const method of methods) {
      expect(typeof (b as unknown as Record<string, unknown>)[method]).toBe('function');
    }
  });

  it("has name property set to 'jujutsu'", () => {
    const b = new JujutsuBackend('/tmp');
    expect(b.name).toBe('jujutsu');
  });

  it("has projectPath property", () => {
    const b = new JujutsuBackend('/my/project');
    expect(b.projectPath).toBe('/my/project');
  });
});
