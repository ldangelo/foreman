/**
 * Tests for silently-ignored new files detection in finalize().
 *
 * Since finalize() is not exported, these tests exercise the underlying git
 * command mechanism (`git ls-files --others --ignored --exclude-standard`)
 * that the implementation relies on. This validates that the detection logic
 * correctly identifies files skipped by `git add -A` due to .gitignore.
 */
import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

function makeGitRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-finalize-test-")));
  tempDirs.push(dir);
  execFileSync("git", ["init", "--initial-branch=main"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

/**
 * Mirrors the detection logic used in finalize() after `git add -A`.
 */
function detectIgnoredFiles(repoDir: string): string[] {
  const opts = { cwd: repoDir, stdio: "pipe" as const };
  const output = execFileSync(
    "git",
    ["ls-files", "--others", "--ignored", "--exclude-standard"],
    opts,
  )
    .toString()
    .trim();
  return output ? output.split("\n").filter(Boolean) : [];
}

describe("finalize() silently-ignored files detection", () => {
  it("detects no ignored files when none are present", () => {
    const repo = makeGitRepo();
    // Create a normal tracked file and stage everything
    writeFileSync(join(repo, "feature.ts"), "export const x = 1;\n");
    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    expect(ignored).toHaveLength(0);
  });

  it("detects a .env file ignored by .gitignore", () => {
    const repo = makeGitRepo();
    writeFileSync(join(repo, ".gitignore"), ".env\n");
    execFileSync("git", ["add", ".gitignore"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add gitignore"], { cwd: repo });

    // Create an ignored file
    writeFileSync(join(repo, ".env"), "SECRET=hunter2\n");
    // Create a normal file
    writeFileSync(join(repo, "index.ts"), "export {};\n");

    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    expect(ignored).toContain(".env");
    // The normal file should NOT appear as ignored (it got staged)
    expect(ignored).not.toContain("index.ts");
  });

  it("detects multiple ignored files matching different patterns", () => {
    const repo = makeGitRepo();
    writeFileSync(join(repo, ".gitignore"), "*.db\ndist/\n.env\n");
    execFileSync("git", ["add", ".gitignore"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add gitignore"], { cwd: repo });

    writeFileSync(join(repo, "data.db"), "binary\n");
    writeFileSync(join(repo, ".env"), "KEY=secret\n");
    writeFileSync(join(repo, "src.ts"), "const x = 1;\n");
    // Create a file inside a `dist/` directory to exercise directory-pattern matching
    mkdirSync(join(repo, "dist"));
    writeFileSync(join(repo, "dist", "output.js"), "\"use strict\";\n");

    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    expect(ignored).toContain("data.db");
    expect(ignored).toContain(".env");
    // dist/output.js (or dist/ directory entry) should appear as ignored
    expect(ignored.some((f) => f.startsWith("dist/"))).toBe(true);
    expect(ignored).not.toContain("src.ts");
  });

  it("returns empty list when all new files are staged (none ignored)", () => {
    const repo = makeGitRepo();
    writeFileSync(join(repo, ".gitignore"), "*.log\n");
    execFileSync("git", ["add", ".gitignore"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add gitignore"], { cwd: repo });

    writeFileSync(join(repo, "module.ts"), "export const val = 42;\n");
    writeFileSync(join(repo, "utils.ts"), "export function helper() {}\n");

    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    expect(ignored).toHaveLength(0);
  });

  it("correctly enumerates more than 500 ignored files (large-list fast-path scenario)", () => {
    const repo = makeGitRepo();
    writeFileSync(join(repo, ".gitignore"), "*.gen\n");
    execFileSync("git", ["add", ".gitignore"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add gitignore"], { cwd: repo });

    // Create 510 ignored files and 1 normal file
    for (let i = 0; i < 510; i++) {
      writeFileSync(join(repo, `file${i}.gen`), `// generated ${i}\n`);
    }
    writeFileSync(join(repo, "keeper.ts"), "export {};\n");

    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    // All 510 .gen files should be detected
    expect(ignored.length).toBe(510);
    // The normal file should not appear
    expect(ignored).not.toContain("keeper.ts");
  });

  it("does not include already-tracked files that match .gitignore patterns", () => {
    const repo = makeGitRepo();
    // Commit a file before adding it to .gitignore
    writeFileSync(join(repo, "tracked.db"), "already tracked\n");
    execFileSync("git", ["add", "tracked.db"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "track file"], { cwd: repo });

    // Now add it to .gitignore (too late — it's already tracked)
    writeFileSync(join(repo, ".gitignore"), "*.db\n");
    execFileSync("git", ["add", "-A"], { cwd: repo });

    const ignored = detectIgnoredFiles(repo);
    // tracked.db is already in the index, so it won't appear as an untracked ignored file
    expect(ignored).not.toContain("tracked.db");
  });
});
