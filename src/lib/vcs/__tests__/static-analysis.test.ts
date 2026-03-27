/**
 * TRD-034: Static Analysis Gate — VCS Encapsulation Enforcement
 *
 * These tests ensure that no NEW code outside the designated backend files
 * makes direct calls to the `git` or `jj` CLI via execFile/execFileSync/spawn.
 *
 * This enforces the VCS encapsulation contract going forward. Files listed in
 * the allowlists below are known legacy callers that have not yet been migrated
 * to use VcsBackend; they must not ADD new direct CLI calls.
 *
 * ## Designated backend files (always allowed):
 * - src/lib/vcs/git-backend.ts  — GitBackend (primary VCS implementation)
 * - src/lib/vcs/jujutsu-backend.ts — JujutsuBackend
 * - src/lib/git.ts — backward-compat shim (delegates to GitBackend)
 *
 * ## Legacy callers (allowed, pending migration to VcsBackend):
 * These files have direct git calls from before the VCS abstraction layer.
 * They are tracked here so that no new files join this list unintentionally.
 * See TRD-2026-004 for migration roadmap.
 */

import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

// ── Allowed files for direct git CLI calls ─────────────────────────────────

/**
 * Files permitted to make direct execFile("git", ...) calls.
 * "Primary" = VCS backend / shim; "Legacy" = pre-abstraction code awaiting migration.
 */
const ALLOWED_DIRECT_GIT = new Set([
  // ── Primary backend files (always allowed) ──
  "src/lib/vcs/git-backend.ts",
  "src/lib/vcs/jujutsu-backend.ts",   // jj colocated repos also use git for some ops
  "src/lib/git.ts",

  // ── Legacy orchestration callers (pre-VCS abstraction) ──
  // These were written before Phase A-F migration; tracked here to detect new violations.
  "src/orchestrator/conflict-resolver.ts",   // git merge/checkout during conflict resolution
  "src/orchestrator/refinery.ts",            // git merge/rebase in merge queue processing
  "src/orchestrator/doctor.ts",              // git --version and git config checks
  "src/orchestrator/agent-worker-finalize.ts", // git commit/push in legacy finalize path
  "src/orchestrator/agent-worker.ts",        // git diff for change detection
  "src/orchestrator/merge-queue.ts",         // git rev-parse for branch verification
  "src/orchestrator/sentinel.ts",            // git rev-parse for health checks
]);

// ── Allowed files for direct jj CLI calls ─────────────────────────────────

const ALLOWED_DIRECT_JJ = new Set([
  // ── Primary backend file (always allowed) ──
  "src/lib/vcs/jujutsu-backend.ts",

  // ── Doctor binary checks (allowed) ──
  // Doctor.checkJjBinary() and checkJjVersion() call `jj --version` to detect installation.
  // These are health-check calls, not VCS operations — they do not bypass JujutsuBackend.
  "src/orchestrator/doctor.ts",
]);

// ── Test file & fixture exclusions ────────────────────────────────────────

const EXCLUDE_PATTERNS = [
  /\/__tests__\//,
  /\.test\.ts$/,
  /\.spec\.ts$/,
  /\/node_modules\//,
  /\/dist\//,
  /\.d\.ts$/,
];

// ── Regex patterns for direct CLI calls ───────────────────────────────────

/**
 * Matches execFileAsync("git"), execFileSync("git"), execFile("git"),
 * spawnSync("git"), or spawn("git") — all exec variants.
 *
 * Excludes comment lines (lines starting with // * /*)
 */
const DIRECT_GIT_CALL_REGEX =
  /(?:execFileAsync|execFileSync|execFile|spawnSync|spawn)\s*\(\s*["'`]git["'`]/;

/**
 * Matches execFileAsync("jj"), execFileSync("jj"), execFile("jj") etc.
 */
const DIRECT_JJ_CALL_REGEX =
  /(?:execFileAsync|execFileSync|execFile|spawnSync|spawn)\s*\(\s*["'`]jj["'`]/;

// ── File traversal ─────────────────────────────────────────────────────────

function collectTsFiles(dir: string): string[] {
  const results: string[] = [];
  try {
    const entries = readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules" && entry.name !== "dist") {
          results.push(...collectTsFiles(fullPath));
        }
      } else if (entry.isFile() && entry.name.endsWith(".ts")) {
        results.push(fullPath);
      }
    }
  } catch {
    // directory doesn't exist — skip
  }
  return results;
}

function isExcluded(filePath: string): boolean {
  return EXCLUDE_PATTERNS.some((p) => p.test(filePath));
}

function getProjectRoot(): string {
  // Walk up from current file until we find package.json
  let dir = new URL(import.meta.url).pathname;
  let prev = "";
  while (dir !== prev) {
    prev = dir;
    dir = join(dir, "..");
    try {
      statSync(join(dir, "package.json"));
      return dir;
    } catch {
      // continue
    }
  }
  throw new Error("Could not find project root (package.json)");
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("TRD-034: Static analysis — VCS CLI encapsulation", () => {
  const projectRoot = getProjectRoot();
  const srcDir = join(projectRoot, "src");

  it("no NEW files (outside allowlist) make direct git CLI calls", () => {
    const allFiles = collectTsFiles(srcDir);
    const violations: string[] = [];

    for (const absPath of allFiles) {
      const relPath = relative(projectRoot, absPath).replace(/\\/g, "/");

      if (isExcluded(relPath)) continue;
      if (ALLOWED_DIRECT_GIT.has(relPath)) continue;

      const content = readFileSync(absPath, "utf-8");
      const lines = content.split("\n");

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trimStart();
        // Skip comment lines
        if (
          trimmed.startsWith("//") ||
          trimmed.startsWith("*") ||
          trimmed.startsWith("/*")
        ) {
          continue;
        }

        if (DIRECT_GIT_CALL_REGEX.test(line)) {
          violations.push(`${relPath}:${i + 1}: ${trimmed.slice(0, 120)}`);
        }
      }
    }

    if (violations.length > 0) {
      throw new Error(
        `TRD-034 VIOLATION: New direct git CLI calls found outside allowed files.\n` +
        `Add the file to ALLOWED_DIRECT_GIT in static-analysis.test.ts ONLY if this is\n` +
        `a legitimate temporary legacy caller awaiting VcsBackend migration.\n\n` +
        `Violations (${violations.length}):\n` +
        violations.map((v) => `  • ${v}`).join("\n") + "\n\n" +
        `Preferred fix: route git calls through VcsBackend (src/lib/vcs/git-backend.ts).`,
      );
    }

    expect(violations.length).toBe(0);
  });

  it("no NEW files (outside allowlist) make direct jj CLI calls", () => {
    const allFiles = collectTsFiles(srcDir);
    const violations: string[] = [];

    for (const absPath of allFiles) {
      const relPath = relative(projectRoot, absPath).replace(/\\/g, "/");

      if (isExcluded(relPath)) continue;
      if (ALLOWED_DIRECT_JJ.has(relPath)) continue;

      const content = readFileSync(absPath, "utf-8");
      const lines = content.split("\n");

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trimStart();
        if (
          trimmed.startsWith("//") ||
          trimmed.startsWith("*") ||
          trimmed.startsWith("/*")
        ) {
          continue;
        }

        if (DIRECT_JJ_CALL_REGEX.test(line)) {
          violations.push(`${relPath}:${i + 1}: ${trimmed.slice(0, 120)}`);
        }
      }
    }

    if (violations.length > 0) {
      throw new Error(
        `TRD-034 VIOLATION: New direct jj CLI calls found outside allowed files.\n` +
        `Violations (${violations.length}):\n` +
        violations.map((v) => `  • ${v}`).join("\n") + "\n\n" +
        `All jj calls must go through JujutsuBackend (src/lib/vcs/jujutsu-backend.ts).`,
      );
    }

    expect(violations.length).toBe(0);
  });

  it("git-backend.ts contains at least one execFile('git') call (sanity check)", () => {
    const gitBackendPath = join(srcDir, "lib", "vcs", "git-backend.ts");
    const content = readFileSync(gitBackendPath, "utf-8");
    expect(DIRECT_GIT_CALL_REGEX.test(content)).toBe(true);
  });

  it("jujutsu-backend.ts contains at least one execFile('jj') call (sanity check)", () => {
    const jjBackendPath = join(srcDir, "lib", "vcs", "jujutsu-backend.ts");
    const content = readFileSync(jjBackendPath, "utf-8");
    expect(DIRECT_JJ_CALL_REGEX.test(content)).toBe(true);
  });

  it("allowlist size is stable — no new legacy callers added without review", () => {
    // The total number of allowed direct-git callers (minus the primary backend files).
    // If this count increases, a reviewer must explicitly approve the new legacy exception.
    // Primary files (git-backend.ts, jujutsu-backend.ts, git.ts) = 3; legacy callers = 7
    const primaryGitFiles = 3;
    const legacyGitCallers = ALLOWED_DIRECT_GIT.size - primaryGitFiles;

    expect(legacyGitCallers).toBeLessThanOrEqual(7);

    // jj allowed: primary backend file (1) + doctor health-check (1)
    const primaryJjFiles = 1;
    const legacyJjCallers = ALLOWED_DIRECT_JJ.size - primaryJjFiles;
    expect(legacyJjCallers).toBeLessThanOrEqual(1);
  });
});
