/**
 * Architectural compliance test: No direct git calls outside VCS backend layer.
 *
 * Verifies that orchestration code does not bypass VcsBackend by calling
 * `execFileAsync("git", ...)` or `execFileSync("git", ...)` directly.
 *
 * Covers: AC-T-016-1, AC-T-016-2
 *
 * --- Allowed Files ---
 * The following files are permitted to contain direct git calls:
 *
 *   src/lib/vcs/git-backend.ts   — The GitBackend implementation. All direct
 *                                   git calls MUST live here.
 *   src/lib/vcs/jujutsu-backend.ts — JujutsuBackend may call git for hybrid
 *                                     jj+git operations (git push, etc.)
 *   src/lib/git.ts               — Legacy backward-compat shim. Deprecated
 *                                   functions delegated from pre-VcsBackend era.
 *   src/orchestrator/refinery.ts — Contains `gitSpecial()` helper for
 *                                   specialized merge operations not exposed
 *                                   by VcsBackend (git apply/index helpers,
 *                                   etc.). Justified with inline comments.
 *   src/orchestrator/doctor.ts   — Health check / diagnostic tool. Uses git
 *                                   for version checks, config reads, and
 *                                   worktree prune operations.
 *
 * --- Known Violations (TODO: migrate in TRD-016) ---
 * The following files contain direct git calls that should be migrated to
 * VcsBackend but are tracked as known exceptions until TRD-016 is resolved.
 *
 * Currently empty — remove/add entries here as real exceptions change.
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
const ALWAYS_ALLOWED: string[] = [
  // VCS backend implementations — these ARE the git layer
  "lib/vcs/git-backend.ts",
  "lib/vcs/jujutsu-backend.ts",
  // Legacy shim — allowed indefinitely for backward compat
  "lib/git.ts",
  // Refinery special ops — documented in gitSpecial() wrapper
  "orchestrator/refinery.ts",
  // Doctor diagnostic tool — version checks, worktree prune
  "orchestrator/doctor.ts",
  // ProjectRegistry — health check git fetch on project clones
  "lib/project-registry.ts",
  // WorktreeManager — manages ~/.foreman/worktrees/<project-id>/ path (distinct from
  // VcsBackend's .foreman-worktrees/ path). Uses direct git for path-specific control.
  "lib/worktree-manager.ts",
  // PR state service — uses git rev-parse and gh pr view for PR state tracking
  "lib/pr-state.ts",
];

/**
 * Files with known violations that are tracked but not yet migrated.
 *
 * TODO(TRD-016): Remove each entry as it is migrated to VcsBackend.
 * See: https://github.com/Fortium/foreman/issues/TRD-016
 */
const KNOWN_VIOLATIONS: Record<string, string> = {};

/** Test files are allowed to use direct git calls for test infrastructure. */
function isTestFile(relPath: string): boolean {
  return relPath.includes("__tests__")
    || relPath.endsWith(".test.ts")
    || relPath.endsWith(".spec.ts")
    || relPath.startsWith("test-support/");
}

/** Return true if a file is in the always-allowed list. */
function isAlwaysAllowed(relPath: string): boolean {
  return ALWAYS_ALLOWED.some((allowed) => relPath === allowed || relPath.endsWith(`/${allowed}`));
}

/** Return true if a file is a documented known violation. */
function isKnownViolation(relPath: string): boolean {
  return Object.keys(KNOWN_VIOLATIONS).some(
    (v) => relPath === v || relPath.endsWith(`/${v}`),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("AC-T-016: No direct git calls outside VCS backend layer", () => {
  const srcDir = srcPath();
  const allTsFiles = collectTsFiles(srcDir);

  /**
   * AC-T-016-1: Zero unexpected execFileAsync("git" calls outside backend.
   *
   * Scans all .ts source files for `execFileAsync("git"`.
   * Allows:
   *   - Always-allowed backend/shim/diagnostic files
   *   - Test files (test setup infrastructure)
   *   - Documented known violations (tracked in KNOWN_VIOLATIONS)
   * Fails if any OTHER file contains the pattern.
   */
  it("AC-T-016-1: no unexpected execFileAsync(\"git\" calls outside VCS backend", () => {
    const PATTERN = 'execFileAsync("git"';
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — test setup infrastructure is allowed
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files
      if (isAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for TRD-016)
      if (isKnownViolation(relPath)) continue;

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
        `Found ${unexpectedViolations.length} unexpected direct git call(s) outside VCS backend:`,
        "",
        ...unexpectedViolations.map((v) => `  • ${v}`),
        "",
        "To fix: route these through VcsBackend methods (see src/lib/vcs/interface.ts).",
        "If the call is genuinely unavoidable, add the file to ALWAYS_ALLOWED or KNOWN_VIOLATIONS",
        "in src/lib/vcs/__tests__/no-direct-git.test.ts with a justification comment.",
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * AC-T-016-2: Zero unexpected execFileSync("git" calls outside backend.
   *
   * Same as AC-T-016-1 but checks the synchronous variant.
   */
  it("AC-T-016-2: no unexpected execFileSync(\"git\" calls outside VCS backend", () => {
    const PATTERN = 'execFileSync("git"';
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — test setup infrastructure is allowed
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files
      if (isAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for TRD-016)
      if (isKnownViolation(relPath)) continue;

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
        "If the call is genuinely unavoidable, add the file to ALWAYS_ALLOWED or KNOWN_VIOLATIONS",
        "in src/lib/vcs/__tests__/no-direct-git.test.ts with a justification comment.",
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * Informational: list all known violations so reviewers can track TRD-016 progress.
   *
   * This test always passes — it just prints the remaining migration backlog.
   */
  it("known violations inventory (informational — does not fail)", () => {
    const allKnown = Object.entries(KNOWN_VIOLATIONS);
    // Just verify the KNOWN_VIOLATIONS map is well-formed (non-empty string values)
    for (const [file, reason] of allKnown) {
      expect(typeof file).toBe("string");
      expect(file.length).toBeGreaterThan(0);
      expect(typeof reason).toBe("string");
      expect(reason.length).toBeGreaterThan(0);
    }
    // Emit a console note so CI logs show remaining migration work
    if (allKnown.length > 0) {
      console.log(
        `\n[TRD-016] ${allKnown.length} known violation(s) remaining to migrate:\n` +
          allKnown.map(([f, r]) => `  • ${f} — ${r}`).join("\n") +
          "\n",
      );
    }
    expect(allKnown.length).toBeGreaterThanOrEqual(0); // always passes
  });
});
