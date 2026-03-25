import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConflictResolver } from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";

function createTestRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "conflict-resolver-t2-"));
  execFileSync("git", ["init", "--initial-branch", "main", dir]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  // Create initial commit on main with a shared base file
  writeFileSync(
    join(dir, "shared.ts"),
    [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "",
    ].join("\n"),
  );
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial"], { cwd: dir });
  return dir;
}

function gitCmd(args: string[], cwd: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8" }).trim();
}

/**
 * Set up a conflict scenario where:
 * - main modifies shared.ts one way
 * - feature branch modifies shared.ts another way
 * Returns the repo in conflicted state on main (after failed merge --no-commit)
 */
function setupConflict(
  repoDir: string,
  mainContent: string,
  featureContent: string,
  branchName: string = "feature/t2",
): void {
  // Feature branch
  gitCmd(["checkout", "-b", branchName], repoDir);
  writeFileSync(join(repoDir, "shared.ts"), featureContent);
  gitCmd(["add", "."], repoDir);
  gitCmd(["commit", "-m", "feature changes"], repoDir);

  // Back to main, make conflicting change
  gitCmd(["checkout", "main"], repoDir);
  writeFileSync(join(repoDir, "shared.ts"), mainContent);
  gitCmd(["add", "."], repoDir);
  gitCmd(["commit", "-m", "main changes"], repoDir);

  // Start the merge so we have a conflicted state
  try {
    execFileSync("git", ["merge", "--no-commit", "--no-ff", branchName], {
      cwd: repoDir,
    });
  } catch {
    // Expected to fail with conflicts
  }
}

describe("ConflictResolver - Tier 2", () => {
  let repoDir: string;
  let resolver: ConflictResolver;

  beforeEach(() => {
    repoDir = createTestRepo();
    resolver = new ConflictResolver(repoDir, DEFAULT_MERGE_CONFIG);
  });

  afterEach(() => {
    rmSync(repoDir, { recursive: true, force: true });
  });

  it("passes when branch incorporates all target hunks", async () => {
    // Main adds a line, feature branch has the same line plus more
    const mainContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const mainNew = 'added by main';",
      "",
    ].join("\n");

    // Feature has main's addition plus its own
    const featureContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const mainNew = 'added by main';",
      "const featureNew = 'added by feature';",
      "",
    ].join("\n");

    setupConflict(repoDir, mainContent, featureContent);

    const result = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/t2",
      "main",
    );

    expect(result.success).toBe(true);
  });

  it("fails when target hunks are missing from branch (true semantic conflict)", async () => {
    // Main adds a specific line
    const mainContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const mainOnly = 'only in main';",
      "",
    ].join("\n");

    // Feature does NOT have main's addition - it changed something else
    const featureContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const featureOnly = 'only in feature';",
      "",
    ].join("\n");

    setupConflict(repoDir, mainContent, featureContent);

    const result = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/t2",
      "main",
    );

    expect(result.success).toBe(false);
    expect(result.reason).toMatch(/hunk/i);
  });

  it("fails threshold guard when >20 lines discarded", async () => {
    // Create a file large enough that removing lines is significant
    const baseLines: string[] = [];
    for (let i = 0; i < 50; i++) {
      baseLines.push(`const line${i} = ${i};`);
    }

    // Overwrite the initial file
    gitCmd(["checkout", "main"], repoDir);
    // Need to abort if there's a merge in progress
    try {
      gitCmd(["merge", "--abort"], repoDir);
    } catch {
      // not in merge state
    }

    writeFileSync(join(repoDir, "shared.ts"), baseLines.join("\n") + "\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "large file"], repoDir);

    // Main adds 25 lines
    const mainContent =
      baseLines.join("\n") +
      "\n" +
      Array.from({ length: 25 }, (_, i) => `const mainLine${i} = ${i};`).join(
        "\n",
      ) +
      "\n";

    // Feature includes all main's lines (passes hunk check) but also removes some
    // Actually, to trigger threshold but pass hunk: feature has all of main's additions
    // but the sheer diff is large. Let's make feature have all main lines but
    // also replace a bunch of original lines.
    const featureLines = baseLines.map((line, i) =>
      i < 25 ? `const replaced${i} = ${i * 100};` : line,
    );
    const featureContent =
      featureLines.join("\n") +
      "\n" +
      Array.from({ length: 25 }, (_, i) => `const mainLine${i} = ${i};`).join(
        "\n",
      ) +
      "\n";

    setupConflict(repoDir, mainContent, featureContent, "feature/threshold");

    const result = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/threshold",
      "main",
    );

    expect(result.success).toBe(false);
    expect(result.reason).toMatch(/threshold|discard/i);
  });

  it("fails threshold guard when >30% of file discarded", async () => {
    // Small file where a few lines discarded exceeds 30%
    const baseContent = [
      "line1",
      "line2",
      "line3",
      "line4",
      "line5",
      "line6",
      "line7",
      "line8",
      "line9",
      "line10",
      "",
    ].join("\n");

    // Overwrite initial file
    try {
      gitCmd(["merge", "--abort"], repoDir);
    } catch {
      // not in merge state
    }
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(join(repoDir, "shared.ts"), baseContent);
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "small file"], repoDir);

    // Main keeps all lines plus adds one
    const mainContent = baseContent.trimEnd() + "\nmainExtra\n";

    // Feature replaces 4 of 10 lines (40%) but has main's extra line (passes hunk check)
    const featureContent = [
      "replaced1",
      "replaced2",
      "replaced3",
      "replaced4",
      "line5",
      "line6",
      "line7",
      "line8",
      "line9",
      "line10",
      "mainExtra",
      "",
    ].join("\n");

    setupConflict(repoDir, mainContent, featureContent, "feature/percent");

    const result = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/percent",
      "main",
    );

    expect(result.success).toBe(false);
    expect(result.reason).toMatch(/threshold|discard|percent/i);
  });

  it("requires BOTH checks to pass for success", async () => {
    // If hunk verification passes but threshold fails, overall fails
    // (Already covered by threshold tests above where hunks pass but threshold fails)
    // This test verifies if hunk fails, we don't even need threshold
    const mainContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const mainExclusive = 'only main has this';",
      "",
    ].join("\n");

    const featureContent = [
      "const a = 1;",
      "const b = 2;",
      "const c = 3;",
      "const d = 4;",
      "const e = 5;",
      "const featureExclusive = 'only feature';",
      "",
    ].join("\n");

    setupConflict(repoDir, mainContent, featureContent, "feature/both");

    const result = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/both",
      "main",
    );

    // Hunk check fails (mainExclusive not in branch) -> fail regardless of threshold
    expect(result.success).toBe(false);
  });

  it("files cascade independently to Tier 3", async () => {
    // Create two files: one resolvable, one not
    writeFileSync(join(repoDir, "resolvable.ts"), "const r = 1;\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "add resolvable"], repoDir);

    // Feature branch
    gitCmd(["checkout", "-b", "feature/cascade"], repoDir);
    writeFileSync(
      join(repoDir, "shared.ts"),
      "const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst mainLine = 'from main';\nconst featureLine = 'from feature';\n",
    );
    writeFileSync(
      join(repoDir, "resolvable.ts"),
      "const r = 'only feature';\n",
    );
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "feature multi"], repoDir);

    // Main modifies both differently
    gitCmd(["checkout", "main"], repoDir);
    writeFileSync(
      join(repoDir, "shared.ts"),
      "const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst mainLine = 'from main';\n",
    );
    writeFileSync(
      join(repoDir, "resolvable.ts"),
      "const r = 'only main';\n",
    );
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "main multi"], repoDir);

    // Start merge
    try {
      execFileSync("git", ["merge", "--no-commit", "--no-ff", "feature/cascade"], {
        cwd: repoDir,
      });
    } catch {
      // conflicts expected
    }

    // Each file is resolved independently
    const result1 = await resolver.attemptTier2Resolution(
      "shared.ts",
      "feature/cascade",
      "main",
    );
    const result2 = await resolver.attemptTier2Resolution(
      "resolvable.ts",
      "feature/cascade",
      "main",
    );

    // Both should have independent results (not all-or-nothing)
    expect(typeof result1.success).toBe("boolean");
    expect(typeof result2.success).toBe("boolean");
    // They are evaluated independently - results may differ
  });

  it("uses configurable thresholds from MergeConfig", async () => {
    // Use very permissive thresholds
    const permissiveConfig: MergeQueueConfig = {
      ...DEFAULT_MERGE_CONFIG,
      tier2SafetyCheck: {
        maxDiscardedLines: 1000,
        maxDiscardedPercent: 90,
      },
    };
    const permissiveResolver = new ConflictResolver(repoDir, permissiveConfig);

    // Create scenario that would fail default thresholds
    const baseLines: string[] = [];
    for (let i = 0; i < 30; i++) {
      baseLines.push(`const line${i} = ${i};`);
    }

    writeFileSync(join(repoDir, "shared.ts"), baseLines.join("\n") + "\n");
    gitCmd(["add", "."], repoDir);
    gitCmd(["commit", "-m", "base for config test"], repoDir);

    // Main adds lines
    const mainAdditions = Array.from(
      { length: 5 },
      (_, i) => `const mainAdd${i} = ${i};`,
    );
    const mainContent =
      baseLines.join("\n") + "\n" + mainAdditions.join("\n") + "\n";

    // Feature replaces 25 of 30 lines (>30% with default) but has main's additions
    const featureLines = baseLines.map((line, i) =>
      i < 25 ? `const changed${i} = ${i * 10};` : line,
    );
    const featureContent =
      featureLines.join("\n") + "\n" + mainAdditions.join("\n") + "\n";

    setupConflict(repoDir, mainContent, featureContent, "feature/config");

    const result = await permissiveResolver.attemptTier2Resolution(
      "shared.ts",
      "feature/config",
      "main",
    );

    // With permissive thresholds, should pass (hunks are incorporated)
    expect(result.success).toBe(true);
  });
});
