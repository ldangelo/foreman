import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConflictResolver } from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { UntrackedCheckResult } from "../conflict-resolver.js";

function createTestRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "conflict-resolver-untracked-"));
  execFileSync("git", ["init", "--initial-branch", "main", dir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  // Create initial commit on main
  writeFileSync(join(dir, "existing.ts"), "const x = 1;\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial"], { cwd: dir });
  return dir;
}

function gitCmd(args: string[], cwd: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8" }).trim();
}

describe("ConflictResolver - Untracked File Conflict Prevention", () => {
  let repoDir: string;
  let resolver: ConflictResolver;

  beforeEach(() => {
    repoDir = createTestRepo();
    resolver = new ConflictResolver(repoDir, DEFAULT_MERGE_CONFIG);
  });

  afterEach(() => {
    rmSync(repoDir, { recursive: true, force: true });
  });

  it("detects untracked files that conflict with branch additions", async () => {
    // Create a feature branch that adds new-file.ts
    gitCmd(["checkout", "-b", "feature/add-file"], repoDir);
    writeFileSync(join(repoDir, "new-file.ts"), "export const y = 2;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add new file"], repoDir);

    // Go back to main and create an untracked file with the same name
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "new-file.ts"), "untracked content\n");

    const result = await resolver.checkUntrackedConflicts(
      "feature/add-file",
      "main",
    );

    expect(result.conflicts).toContain("new-file.ts");
    expect(result.action).toBe("deleted");
  });

  it("returns 'none' when no untracked conflicts exist", async () => {
    // Create a feature branch with a new file
    gitCmd(["checkout", "-b", "feature/clean"], repoDir);
    writeFileSync(join(repoDir, "clean-file.ts"), "export const z = 3;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add clean file"], repoDir);

    // Go back to main — no untracked files matching
    gitCmd(["checkout", "main"], repoDir);

    const result = await resolver.checkUntrackedConflicts(
      "feature/clean",
      "main",
    );

    expect(result.conflicts).toEqual([]);
    expect(result.action).toBe("none");
  });

  it("default 'delete' mode removes conflicting untracked files", async () => {
    // Create feature branch adding a file
    gitCmd(["checkout", "-b", "feature/add-file"], repoDir);
    writeFileSync(join(repoDir, "conflict.ts"), "export const a = 1;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add conflict file"], repoDir);

    // Create untracked file on main
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "conflict.ts"), "untracked content\n");

    const result = await resolver.checkUntrackedConflicts(
      "feature/add-file",
      "main",
      "delete",
    );

    expect(result.action).toBe("deleted");
    expect(result.conflicts).toContain("conflict.ts");
    // File should be deleted
    expect(existsSync(join(repoDir, "conflict.ts"))).toBe(false);
  });

  it("stash mode moves conflicting files to .foreman/stashed/<timestamp>/", async () => {
    // Create feature branch adding a file
    gitCmd(["checkout", "-b", "feature/add-file"], repoDir);
    writeFileSync(join(repoDir, "stash-me.ts"), "export const b = 2;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add stash file"], repoDir);

    // Create untracked file on main
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "stash-me.ts"), "untracked stash content\n");

    const result = await resolver.checkUntrackedConflicts(
      "feature/add-file",
      "main",
      "stash",
    );

    expect(result.action).toBe("stashed");
    expect(result.conflicts).toContain("stash-me.ts");
    expect(result.stashPath).toBeDefined();
    expect(result.stashPath).toContain(".foreman/stashed/");

    // Original file should be gone
    expect(existsSync(join(repoDir, "stash-me.ts"))).toBe(false);

    // Stashed file should exist
    const stashedFile = join(result.stashPath!, "stash-me.ts");
    expect(existsSync(stashedFile)).toBe(true);
    expect(readFileSync(stashedFile, "utf-8")).toBe("untracked stash content\n");
  });

  it("abort mode returns error with listing and MQ-014 error code", async () => {
    // Create feature branch adding a file
    gitCmd(["checkout", "-b", "feature/add-file"], repoDir);
    writeFileSync(join(repoDir, "abort-me.ts"), "export const c = 3;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add abort file"], repoDir);

    // Create untracked file on main
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "abort-me.ts"), "untracked abort content\n");

    const result = await resolver.checkUntrackedConflicts(
      "feature/add-file",
      "main",
      "abort",
    );

    expect(result.action).toBe("aborted");
    expect(result.conflicts).toContain("abort-me.ts");
    expect(result.errorCode).toBe("MQ-014");

    // File should NOT be deleted in abort mode
    expect(existsSync(join(repoDir, "abort-me.ts"))).toBe(true);
  });

  it("handles multiple conflicting untracked files", async () => {
    // Create feature branch adding multiple files
    gitCmd(["checkout", "-b", "feature/multi"], repoDir);
    writeFileSync(join(repoDir, "file-a.ts"), "export const a = 1;\n");
    writeFileSync(join(repoDir, "file-b.ts"), "export const b = 2;\n");
    writeFileSync(join(repoDir, "file-c.ts"), "export const c = 3;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add multiple files"], repoDir);

    // Create only some as untracked on main (partial overlap)
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "file-a.ts"), "untracked a\n");
    writeFileSync(join(repoDir, "file-c.ts"), "untracked c\n");

    const result = await resolver.checkUntrackedConflicts(
      "feature/multi",
      "main",
      "delete",
    );

    expect(result.conflicts).toHaveLength(2);
    expect(result.conflicts).toContain("file-a.ts");
    expect(result.conflicts).toContain("file-c.ts");
    expect(result.action).toBe("deleted");
  });
});
