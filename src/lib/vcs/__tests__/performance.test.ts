/**
 * Performance tests for VcsBackend overhead.
 *
 * AC-T-029-1: 100 GitBackend.getRepoRoot() calls have < 5ms average overhead
 *             compared to direct execFileAsync git invocations.
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

// ── AC-T-029-1: Overhead Benchmark ───────────────────────────────────────────

describe("AC-T-029-1: GitBackend getRepoRoot() overhead vs direct git", () => {
  it(
    "100 getRepoRoot() calls have < 5ms average overhead per call",
    async () => {
      const repo = makeTempRepo();
      tempDirs.push(repo);
      const backend = new GitBackend(repo);

      const ITERATIONS = 100;
      const WARMUP = 3;

      // --- Warmup: both paths to avoid initialization noise ---
      for (let i = 0; i < WARMUP; i++) {
        await backend.getRepoRoot(repo);
        await execFileAsync("git", ["rev-parse", "--show-toplevel"], {
          cwd: repo,
          maxBuffer: 10 * 1024 * 1024,
          env: { ...process.env, GIT_EDITOR: "true" },
        });
      }

      // --- Interleaved benchmark for fair system-load comparison ---
      // Running AAAA...BBBB... batches is vulnerable to system load shifts
      // between batches (e.g. other tests freeing CPU mid-run).  Interleaving
      // ensures both methods experience the same ambient load.
      let backendTotal = 0;
      let directTotal = 0;

      for (let i = 0; i < ITERATIONS; i++) {
        // Backend call
        const t0 = performance.now();
        await backend.getRepoRoot(repo);
        backendTotal += performance.now() - t0;

        // Direct execFileAsync call
        const t1 = performance.now();
        const { stdout } = await execFileAsync(
          "git",
          ["rev-parse", "--show-toplevel"],
          {
            cwd: repo,
            maxBuffer: 10 * 1024 * 1024,
            env: { ...process.env, GIT_EDITOR: "true" },
          },
        );
        // Mirror what GitBackend does: trim stdout
        stdout.trim();
        directTotal += performance.now() - t1;
      }

      const overheadTotal = backendTotal - directTotal;
      // Clamp to zero: if backend was faster the overhead is effectively 0,
      // not a negative value we'd need to worry about.
      const overheadPerCall = Math.max(0, overheadTotal / ITERATIONS);

      console.log(
        `GitBackend ${ITERATIONS}x getRepoRoot: ${backendTotal.toFixed(1)}ms total (${(backendTotal / ITERATIONS).toFixed(2)}ms avg)`,
      );
      console.log(
        `Direct execFileAsync ${ITERATIONS}x: ${directTotal.toFixed(1)}ms total (${(directTotal / ITERATIONS).toFixed(2)}ms avg)`,
      );
      console.log(
        `Overhead per call: ${overheadPerCall.toFixed(2)}ms (threshold: < 5ms)`,
      );

      expect(overheadPerCall).toBeLessThan(5);
    },
    // 30 second timeout — 100 git calls × 2 can take a while on slow CI
    30_000,
  );
});

// ── AC-T-029-2: Error Messages Include Backend Name ──────────────────────────

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

    await expect(backend.getRepoRoot(nonGitDir)).rejects.toThrow(
      /^git /,
    );
  });

  it("GitBackend.name property is 'git'", () => {
    const backend = new GitBackend("/tmp");
    expect(backend.name).toBe("git");
  });
});
