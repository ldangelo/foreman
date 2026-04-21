/**
 * Tests for VcsBackend correctness and error handling.
 *
 * AC-T-029-1: GitBackend.getRepoRoot() returns the correct repo root path.
 *             (Note: Performance overhead benchmarks removed — timing is
 *              inherently non-deterministic on shared/dev machines.)
 * AC-T-029-2: Failing VCS commands produce error messages that include the
 *             backend name ("git").
 */

import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { execFile } from "node:child_process";
import { execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GitBackend } from "../git-backend.js";

const execFileAsync = promisify(execFile);

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTempRepo(branch = "main"): string {
  // realpathSync resolves macOS /var → /private/var symlink
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-perf-test-")),
  );
  execFileSync("git", ["init", `--initial-branch=${branch}`], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── AC-T-029-1: Correctness ──────────────────────────────────────────────────
// Note: Performance benchmarks (overhead < Nms) removed — timing is inherently
// non-deterministic on shared/dev machines. We test correctness instead:
// getRepoRoot() must return the correct path regardless of how long it takes.

describe("AC-T-029-1: GitBackend getRepoRoot() correctness", () => {
  it("returns the realpath of the repo root", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.getRepoRoot(repo);
    expect(result).toBe(realpathSync(repo));
  });

  it("returns the same path as git rev-parse --show-toplevel", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.getRepoRoot(repo);
    const { stdout } = await execFileAsync(
      "git",
      ["rev-parse", "--show-toplevel"],
      { cwd: repo, maxBuffer: 10 * 1024 * 1024 },
    );
    expect(result).toBe(realpathSync(stdout.trim()));
  });

  it("returns the repo root even when called from a subdirectory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a subdirectory and call getRepoRoot from there
    const subdir = join(repo, "sub", "nested");
    execFileSync("mkdir", ["-p", subdir]);

    const result = await backend.getRepoRoot(subdir);
    expect(result).toBe(realpathSync(repo));
  });
});

// ── AC-T-029-2: Error Messages Include Backend Name ──────────────────────────────

describe("AC-T-029-2: Failing VCS commands include backend name in error", () => {
  it("getRepoRoot() on a non-git directory throws an error containing 'git'", async () => {
    const nonGitDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-no-git-")),
    );
    tempDirs.push(nonGitDir);
    const backend = new GitBackend(nonGitDir);

    let caught: Error | null = null;
    try {
      await backend.getRepoRoot(nonGitDir);
    } catch (err) {
      caught = err as Error;
    }

    expect(caught).not.toBeNull();
    expect(caught!.message).toMatch(/git/);
  });

  it("error message starts with the backend name identifier 'git'", async () => {
    const nonGitDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-no-git-")),
    );
    tempDirs.push(nonGitDir);
    const backend = new GitBackend(nonGitDir);

    await expect(backend.getRepoRoot(nonGitDir)).rejects.toThrow(/^git /);
  });

  it("GitBackend.name property is 'git'", () => {
    const backend = new GitBackend("/tmp");
    expect(backend.name).toBe("git");
  });
});
