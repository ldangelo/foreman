import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConflictResolver } from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";

function createTestRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "conflict-resolver-t1-"));
  execFileSync("git", ["init", "--initial-branch", "main", dir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  // Create initial commit on main
  writeFileSync(join(dir, "file.ts"), "const x = 1;\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial"], { cwd: dir });
  return dir;
}

function gitCmd(args: string[], cwd: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8" }).trim();
}

describe("ConflictResolver - Tier 1", () => {
  let repoDir: string;
  let resolver: ConflictResolver;

  beforeEach(() => {
    repoDir = createTestRepo();
    resolver = new ConflictResolver(repoDir, DEFAULT_MERGE_CONFIG);
  });

  afterEach(() => {
    rmSync(repoDir, { recursive: true, force: true });
  });

  it("succeeds when merge has no conflicts", async () => {
    // Create a feature branch with a non-conflicting change
    gitCmd(["checkout", "-b", "feature/clean"], repoDir);
    writeFileSync(join(repoDir, "new-file.ts"), "export const y = 2;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add new file"], repoDir);

    // Go back to main
    gitCmd(["checkout", "main"], repoDir);

    const result = await resolver.attemptMerge("feature/clean", "main");

    expect(result.success).toBe(true);
    expect(result.conflictedFiles).toEqual([]);
  });

  it("detects and lists conflicted files", async () => {
    // Create a feature branch that modifies file.ts
    gitCmd(["checkout", "-b", "feature/conflict"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'from feature';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "feature change"], repoDir);

    // Go back to main and make a conflicting change
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'from main';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "main change"], repoDir);

    const result = await resolver.attemptMerge("feature/conflict", "main");

    expect(result.success).toBe(false);
    expect(result.conflictedFiles).toContain("file.ts");
  });

  it("preserves merge topology (two parents)", async () => {
    // Create a feature branch
    gitCmd(["checkout", "-b", "feature/topology"], repoDir);
    writeFileSync(join(repoDir, "extra.ts"), "export const z = 3;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "topology test"], repoDir);

    // Go back to main - add a different file so branches diverge
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "main-only.ts"), "export const m = 1;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "main diverge"], repoDir);

    const result = await resolver.attemptMerge("feature/topology", "main");
    expect(result.success).toBe(true);

    // Verify merge commit has two parents
    const parents = gitCmd(["log", "-1", "--format=%P"], repoDir);
    const parentHashes = parents.split(/\s+/).filter(Boolean);
    expect(parentHashes.length).toBe(2);
  });

  it("aborts merge when conflicts are detected (clean state)", async () => {
    // Create conflicting branches
    gitCmd(["checkout", "-b", "feature/abort-test"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'feature version';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "feature edit"], repoDir);

    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'main version';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "main edit"], repoDir);

    const result = await resolver.attemptMerge("feature/abort-test", "main");
    expect(result.success).toBe(false);

    // After failed merge, working tree should be clean (merge aborted)
    const status = gitCmd(["status", "--porcelain"], repoDir);
    expect(status).toBe("");
  });

  it("detects multiple conflicted files", async () => {
    // Add a second file on main
    writeFileSync(join(repoDir, "other.ts"), "const a = 1;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add other"], repoDir);

    // Create feature branch modifying both files
    gitCmd(["checkout", "-b", "feature/multi-conflict"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'feature';\n");
    writeFileSync(join(repoDir, "other.ts"), "const a = 'feature';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "feature changes"], repoDir);

    // Main also modifies both
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "file.ts"), "const x = 'main';\n");
    writeFileSync(join(repoDir, "other.ts"), "const a = 'main';\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "main changes"], repoDir);

    const result = await resolver.attemptMerge("feature/multi-conflict", "main");

    expect(result.success).toBe(false);
    expect(result.conflictedFiles).toContain("file.ts");
    expect(result.conflictedFiles).toContain("other.ts");
    expect(result.conflictedFiles.length).toBe(2);
  });
});
