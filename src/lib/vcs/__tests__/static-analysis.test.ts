/**
 * Architectural compliance test: No direct VCS calls outside backend layer.
 *
 * Verifies that orchestration code does not bypass VcsBackend by calling
 * `execFileAsync("git", ...)`, `execFileSync("git", ...)`, or
 * `execFileAsync("jj", ...)` directly outside the designated backend files.
 *
 * Covers: AC-T-034-1
 *
 * --- Allowed Files ---
 * The following files are permitted to contain direct git calls:
 *
 *   src/lib/vcs/git-backend.ts     — The GitBackend implementation. All direct
 *                                     git calls MUST live here.
 *   src/lib/vcs/jujutsu-backend.ts — JujutsuBackend may call git for hybrid
 *                                     jj+git operations (git push, etc.)
 *   src/lib/git.ts                 — Legacy backward-compat shim. Deprecated
 *                                     functions delegated from pre-VcsBackend era.
 *   src/orchestrator/refinery.ts   — Contains `gitSpecial()` helper for
 *                                     specialized merge operations not exposed
 *                                     by VcsBackend (git stash, git reset --hard,
 *                                     git rebase --onto, etc.). Justified with
 *                                     inline comments.
 *   src/orchestrator/doctor.ts     — Health check / diagnostic tool. Uses git
 *                                     for version checks, config reads, and
 *                                     worktree prune operations.
 *
 * The following files are permitted to contain direct jj calls:
 *
 *   src/lib/vcs/jujutsu-backend.ts — The JujutsuBackend implementation. All
 *                                     direct jj calls MUST live here.
 *   src/orchestrator/doctor.ts     — Health check / diagnostic tool. Uses jj
 *                                     for version checks.
 *
 * --- Known Violations (TODO: migrate in TRD-016) ---
 * The following files contain direct git calls that should be migrated to
 * VcsBackend but are tracked as known exceptions until TRD-016 is resolved:
 *
 *   src/orchestrator/sentinel.ts   — `resolveCommit()` uses
 *                                    execFileAsync("git", ["rev-parse", ref]).
 *                                    Should migrate to a VcsBackend.resolveRef()
 *                                    method or getHeadId() equivalent.
 *
 *   src/orchestrator/merge-queue.ts — Branch validation uses
 *                                     execFileAsync("git", ["rev-parse", "--verify", ...]).
 *                                     Should use VcsBackend.branchExists().
 *
 *   src/orchestrator/agent-worker.ts — Merge-queue enqueue uses
 *                                      execFileSync("git", ["diff", "--name-only", ...]).
 *                                      Should use VcsBackend.diff() or getModifiedFiles().
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, it, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

// ── Helpers ───────────────────────────────────────────────────────────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Resolve a path relative to the project root (src/). */
function srcPath(...parts: string[]): string {
  // __dirname is src/lib/vcs/__tests__/
  return join(__dirname, "..", "..", "..", ...parts);
}

/** Recursively collect all .ts files under a directory. */
function collectTsFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      results.push(...collectTsFiles(full));
    } else if (entry.endsWith(".ts")) {
      results.push(full);
    }
  }
  return results;
}

/** Return all lines in a file that contain the given pattern. */
function grepFile(filePath: string, pattern: string): string[] {
  const content = readFileSync(filePath, "utf8");
  return content
    .split("\n")
    .filter((line) => line.includes(pattern));
}

// ── Allowed lists ─────────────────────────────────────────────────────────────

/**
 * Files allowed to contain execFileAsync("git" or execFileSync("git" calls.
 * Paths relative to the src/ directory.
 */
const GIT_ALWAYS_ALLOWED: string[] = [
  // VCS backend implementations — these ARE the git layer
  "lib/vcs/git-backend.ts",
  "lib/vcs/jujutsu-backend.ts",
  // Legacy shim — allowed indefinitely for backward compat
  "lib/git.ts",
  // Refinery special ops — documented in gitSpecial() wrapper
  "orchestrator/refinery.ts",
  // Doctor diagnostic tool — version checks, worktree prune
  "orchestrator/doctor.ts",
];

/**
 * Files allowed to contain execFileAsync("jj" calls.
 * Paths relative to the src/ directory.
 */
const JJ_ALWAYS_ALLOWED: string[] = [
  // JujutsuBackend implementation — this IS the jj layer
  "lib/vcs/jujutsu-backend.ts",
  // Doctor diagnostic tool — version checks
  "orchestrator/doctor.ts",
];

/**
 * Files with known git violations that are tracked but not yet migrated.
 *
 * TODO(TRD-016): Remove each entry as it is migrated to VcsBackend.
 * See: https://github.com/Fortium/foreman/issues/TRD-016
 */
const GIT_KNOWN_VIOLATIONS: Record<string, string> = {
  // resolveCommit() calls execFileAsync("git", ["rev-parse", ref]).
  // Needs: VcsBackend.resolveRef() or equivalent method.
  "orchestrator/sentinel.ts": "TRD-016: resolveCommit() → VcsBackend.resolveRef()",

  // Branch validation calls execFileAsync("git", ["rev-parse", "--verify", ...]).
  // Needs: migrate to VcsBackend.branchExists().
  "orchestrator/merge-queue.ts": "TRD-016: branch check → VcsBackend.branchExists()",

  // Enqueue diff calls execFileSync("git", ["diff", "--name-only", ...]).
  // Needs: migrate to VcsBackend.diff() or getModifiedFiles().
  "orchestrator/agent-worker.ts": "TRD-016: diff for enqueue → VcsBackend.diff()",
};

/**
 * Files with known jj violations that are tracked but not yet migrated.
 *
 * Currently empty — jj calls are properly contained to the backend layer.
 * Add entries here if temporary violations are introduced during migration.
 */
const JJ_KNOWN_VIOLATIONS: Record<string, string> = {};

/** Test files are allowed to use direct VCS calls for test infrastructure. */
function isTestFile(relPath: string): boolean {
  return relPath.includes("__tests__")
    || relPath.endsWith(".test.ts")
    || relPath.endsWith(".spec.ts")
    || relPath.startsWith("test-support/");
}

/** Return true if a file is in the git always-allowed list. */
function isGitAlwaysAllowed(relPath: string): boolean {
  return GIT_ALWAYS_ALLOWED.some((allowed) => relPath === allowed || relPath.endsWith(`/${allowed}`));
}

/** Return true if a file is in the jj always-allowed list. */
function isJjAlwaysAllowed(relPath: string): boolean {
  return JJ_ALWAYS_ALLOWED.some((allowed) => relPath === allowed || relPath.endsWith(`/${allowed}`));
}

/** Return true if a file is a documented known git violation. */
function isGitKnownViolation(relPath: string): boolean {
  return Object.keys(GIT_KNOWN_VIOLATIONS).some(
    (v) => relPath === v || relPath.endsWith(`/${v}`),
  );
}

/** Return true if a file is a documented known jj violation. */
function isJjKnownViolation(relPath: string): boolean {
  return Object.keys(JJ_KNOWN_VIOLATIONS).some(
    (v) => relPath === v || relPath.endsWith(`/${v}`),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("AC-T-034: Static Analysis Gate -- No Direct VCS Calls Outside Backend", () => {
  const srcDir = srcPath();
  const allTsFiles = collectTsFiles(srcDir);

  /**
   * AC-T-034-1 (Part A): Zero unexpected execFileAsync("git" calls outside backend.
   *
   * Scans all .ts source files for `execFileAsync("git"`.
   * Allows:
   *   - Always-allowed backend/shim/diagnostic files
   *   - Test files (test setup infrastructure)
   *   - Documented known violations (tracked in GIT_KNOWN_VIOLATIONS)
   * Fails if any OTHER file contains the pattern.
   */
  it('AC-T-034-1a: no unexpected execFileAsync("git" calls outside VCS backend', () => {
    const PATTERN = 'execFileAsync("git"';
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — test setup infrastructure is allowed
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files
      if (isGitAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for TRD-016)
      if (isGitKnownViolation(relPath)) continue;

      const matches = grepFile(file, PATTERN);
      if (matches.length > 0) {
        for (const line of matches) {
          // Ignore comment-only lines
          const trimmed = line.trim();
          if (trimmed.startsWith("//") || trimmed.startsWith("*")) continue;
          unexpectedViolations.push(`${relPath}: ${trimmed.slice(0, 120)}`);
        }
      }
    }

    if (unexpectedViolations.length > 0) {
      const msg = [
        `Found ${unexpectedViolations.length} unexpected direct async git call(s) outside VCS backend:`,
        "",
        ...unexpectedViolations.map((v) => `  • ${v}`),
        "",
        "To fix: route these through VcsBackend methods (see src/lib/vcs/interface.ts).",
        "If the call is genuinely unavoidable, add the file to GIT_ALWAYS_ALLOWED or GIT_KNOWN_VIOLATIONS",
        "in src/lib/vcs/__tests__/static-analysis.test.ts with a justification comment.",
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * AC-T-034-1 (Part B): Zero unexpected execFileSync("git" calls outside backend.
   *
   * Same as Part A but checks the synchronous variant.
   */
  it('AC-T-034-1b: no unexpected execFileSync("git" calls outside VCS backend', () => {
    const PATTERN = 'execFileSync("git"';
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — test setup infrastructure is allowed
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files
      if (isGitAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for TRD-016)
      if (isGitKnownViolation(relPath)) continue;

      const matches = grepFile(file, PATTERN);
      if (matches.length > 0) {
        for (const line of matches) {
          // Ignore comment-only lines
          const trimmed = line.trim();
          if (trimmed.startsWith("//") || trimmed.startsWith("*")) continue;
          unexpectedViolations.push(`${relPath}: ${trimmed.slice(0, 120)}`);
        }
      }
    }

    if (unexpectedViolations.length > 0) {
      const msg = [
        `Found ${unexpectedViolations.length} unexpected direct synchronous git call(s) outside VCS backend:`,
        "",
        ...unexpectedViolations.map((v) => `  • ${v}`),
        "",
        "To fix: route these through VcsBackend methods (see src/lib/vcs/interface.ts).",
        "If the call is genuinely unavoidable, add the file to GIT_ALWAYS_ALLOWED or GIT_KNOWN_VIOLATIONS",
        "in src/lib/vcs/__tests__/static-analysis.test.ts with a justification comment.",
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * AC-T-034-1 (Part C): Zero unexpected execFileAsync("jj" calls outside backend.
   *
   * Scans all .ts source files for `execFileAsync("jj"`.
   * Allows:
   *   - Always-allowed backend/diagnostic files
   *   - Test files (test setup infrastructure)
   *   - Documented known violations (tracked in JJ_KNOWN_VIOLATIONS)
   * Fails if any OTHER file contains the pattern.
   */
  it('AC-T-034-1c: no unexpected execFileAsync("jj" calls outside VCS backend', () => {
    const PATTERN = 'execFileAsync("jj"';
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — test setup infrastructure is allowed
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files
      if (isJjAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for future TRD)
      if (isJjKnownViolation(relPath)) continue;

      const matches = grepFile(file, PATTERN);
      if (matches.length > 0) {
        for (const line of matches) {
          // Ignore comment-only lines
          const trimmed = line.trim();
          if (trimmed.startsWith("//") || trimmed.startsWith("*")) continue;
          unexpectedViolations.push(`${relPath}: ${trimmed.slice(0, 120)}`);
        }
      }
    }

    if (unexpectedViolations.length > 0) {
      const msg = [
        `Found ${unexpectedViolations.length} unexpected direct jj call(s) outside VCS backend:`,
        "",
        ...unexpectedViolations.map((v) => `  • ${v}`),
        "",
        "To fix: route these through VcsBackend methods (see src/lib/vcs/interface.ts).",
        "If the call is genuinely unavoidable, add the file to JJ_ALWAYS_ALLOWED or JJ_KNOWN_VIOLATIONS",
        "in src/lib/vcs/__tests__/static-analysis.test.ts with a justification comment.",
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * Informational: list all known git violations so reviewers can track TRD-016 progress.
   *
   * This test always passes — it just prints the remaining migration backlog.
   */
  it("known git violations inventory (informational — does not fail)", () => {
    const allKnown = Object.entries(GIT_KNOWN_VIOLATIONS);
    // Just verify the GIT_KNOWN_VIOLATIONS map is well-formed (non-empty string values)
    for (const [file, reason] of allKnown) {
      expect(typeof file).toBe("string");
      expect(file.length).toBeGreaterThan(0);
      expect(typeof reason).toBe("string");
      expect(reason.length).toBeGreaterThan(0);
    }
    // Emit a console note so CI logs show remaining migration work
    if (allKnown.length > 0) {
      console.log(
        `\n[TRD-016] ${allKnown.length} known git violation(s) remaining to migrate:\n` +
          allKnown.map(([f, r]) => `  • ${f} — ${r}`).join("\n") +
          "\n",
      );
    }
    expect(allKnown.length).toBeGreaterThanOrEqual(0); // always passes
  });

  /**
   * Informational: list all known jj violations so reviewers can track progress.
   *
   * This test always passes — it just prints the remaining migration backlog.
   */
  it("known jj violations inventory (informational — does not fail)", () => {
    const allKnown = Object.entries(JJ_KNOWN_VIOLATIONS);
    // Just verify the JJ_KNOWN_VIOLATIONS map is well-formed (non-empty string values)
    for (const [file, reason] of allKnown) {
      expect(typeof file).toBe("string");
      expect(file.length).toBeGreaterThan(0);
      expect(typeof reason).toBe("string");
      expect(reason.length).toBeGreaterThan(0);
    }
    // Emit a console note so CI logs show remaining migration work
    if (allKnown.length > 0) {
      console.log(
        `\n[TRD-034] ${allKnown.length} known jj violation(s) remaining to migrate:\n` +
          allKnown.map(([f, r]) => `  • ${f} — ${r}`).join("\n") +
          "\n",
      );
    }
    expect(allKnown.length).toBeGreaterThanOrEqual(0); // always passes
  });
});
