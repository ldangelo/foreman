/**
 * Architectural compliance test: BeadsRustClient imports must be restricted.
 *
 * Verifies that only the designated files are permitted to import
 * `BeadsRustClient` directly. All other code should depend on the
 * `ITaskClient` abstraction interface instead.
 *
 * Covers: TRD-014 / REQ-015 (Beads Deprecation Path)
 *
 * --- Allowed Files ---
 * The following files are permitted to contain `import.*BeadsRustClient`:
 *
 *   src/lib/beads-rust.ts            — Defines and exports the class itself.
 *
 * --- Known Violations (TODO: migrate — see TRD-014) ---
 * The following files currently import BeadsRustClient directly and must be
 * migrated to use the ITaskClient interface or a higher-level factory.
 * Each entry links to the tracking issue and describes the required change.
 *
 * CLI commands (should receive ITaskClient via dispatcher/factory):
 *
 * Orchestrator (should use ITaskClient interface):
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, it, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

// ── Helpers ───────────────────────────────────────────────────────────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Resolve a path relative to the src/ directory. */
function srcPath(...parts: string[]): string {
  // __dirname is src/lib/__tests__/
  return join(__dirname, "..", "..", ...parts);
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

/** Return all lines in a file that match the given string pattern. */
function grepFile(filePath: string, pattern: string): Array<{ lineNum: number; text: string }> {
  const content = readFileSync(filePath, "utf8");
  return content
    .split("\n")
    .map((text, idx) => ({ lineNum: idx + 1, text }))
    .filter(({ text }) => text.includes(pattern));
}

// ── Allowed lists ─────────────────────────────────────────────────────────────

/**
 * Files permanently allowed to import BeadsRustClient.
 * Paths are relative to the src/ directory.
 */
const BEADS_RUST_ALWAYS_ALLOWED: string[] = [
  // Definition file — the class lives here
  "lib/beads-rust.ts",
];

/**
 * Files with known BeadsRustClient import violations during the deprecation
 * transition period. Each entry maps a src/-relative path to a description
 * of the required migration.
 *
 * TODO(TRD-014): Remove each entry as it is migrated to use ITaskClient.
 */
const BEADS_RUST_KNOWN_VIOLATIONS: Record<string, string> = {
  // ── CLI commands ──────────────────────────────────────────────────────────
};

/** Test files (in __tests__/, or *.test.ts / *.spec.ts) are always exempt. */
function isTestFile(relPath: string): boolean {
  return (
    relPath.includes("__tests__") ||
    relPath.endsWith(".test.ts") ||
    relPath.endsWith(".spec.ts")
  );
}

/** Return true if the file is in the always-allowed list. */
function isAlwaysAllowed(relPath: string): boolean {
  return BEADS_RUST_ALWAYS_ALLOWED.some(
    (allowed) => relPath === allowed || relPath.endsWith(`/${allowed}`),
  );
}

/** Return true if the file is a documented known violation. */
function isKnownViolation(relPath: string): boolean {
  return Object.keys(BEADS_RUST_KNOWN_VIOLATIONS).some(
    (v) => relPath === v || relPath.endsWith(`/${v}`),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("TRD-014 / REQ-015: BeadsRustClient Deprecation Compliance", () => {
  const srcDir = srcPath();
  const allTsFiles = collectTsFiles(srcDir);

  /**
   * REQ-015.1: No unexpected BeadsRustClient imports outside the allowed scope.
   *
   * Scans every .ts source file for lines matching `import.*BeadsRustClient`.
   * Allows:
   *   - `lib/beads-rust.ts` and `orchestrator/dispatcher.ts` (always allowed)
   *   - Test files (__tests__/, *.test.ts, *.spec.ts)
   *   - Documented known violations (tracked in BEADS_RUST_KNOWN_VIOLATIONS)
   * Fails if any OTHER file contains an import of BeadsRustClient.
   */
  it("REQ-015.1: no unexpected BeadsRustClient imports outside allowed scope", () => {
    const PATTERN = "BeadsRustClient";
    const IMPORT_PATTERN = "import";
    const unexpectedViolations: string[] = [];

    for (const file of allTsFiles) {
      const relPath = relative(srcDir, file);

      // Skip test files — allowed to import BeadsRustClient for unit testing
      if (isTestFile(relPath)) continue;

      // Skip always-allowed files (definition + dispatcher fallback)
      if (isAlwaysAllowed(relPath)) continue;

      // Skip documented known violations (tracked for TRD-014 migration)
      if (isKnownViolation(relPath)) continue;

      const matches = grepFile(file, PATTERN);
      for (const { lineNum, text } of matches) {
        const trimmed = text.trim();

        // Skip comment-only lines
        if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")) {
          continue;
        }

        // Only flag static ESM import statements (not dynamic import() expressions
        // used for lazy compatibility shims inside already-migrated modules).
        if (!trimmed.startsWith(IMPORT_PATTERN)) continue;

        unexpectedViolations.push(
          `${relPath}:${lineNum}: ${trimmed.slice(0, 120)}`,
        );
      }
    }

    if (unexpectedViolations.length > 0) {
      const msg = [
        `Found ${unexpectedViolations.length} unexpected import(s) of BeadsRustClient outside allowed scope:`,
        "",
        ...unexpectedViolations.map((v) => `  • ${v}`),
        "",
        "To fix: import ITaskClient from 'src/lib/task-client.ts' instead of BeadsRustClient.",
        "If the violation is unavoidable during the current sprint, add the file to",
        "BEADS_RUST_KNOWN_VIOLATIONS in src/lib/__tests__/beads-rust-deprecation.test.ts",
        "with a TRD-014 reference and a description of the required migration.",
        "",
        "Allowed files:",
        ...BEADS_RUST_ALWAYS_ALLOWED.map((f) => `  • src/${f}`),
      ].join("\n");
      expect.fail(msg);
    }
  });

  /**
   * Informational: list all documented known violations so reviewers can track
   * TRD-014 deprecation progress in CI logs.
   *
   * This test always passes — it never fails the build.
   */
  it("known violations inventory (informational — does not fail)", () => {
    const allKnown = Object.entries(BEADS_RUST_KNOWN_VIOLATIONS);

    // Structural validation: ensure every entry is a non-empty string pair
    for (const [file, reason] of allKnown) {
      expect(typeof file).toBe("string");
      expect(file.length).toBeGreaterThan(0);
      expect(typeof reason).toBe("string");
      expect(reason.length).toBeGreaterThan(0);
    }

    // Emit a console note only when migration work remains
    if (allKnown.length > 0) {
      console.log(
        `\n[TRD-014] ${allKnown.length} known BeadsRustClient violation(s) remaining to migrate to ITaskClient:\n` +
          allKnown.map(([f, r]) => `  • src/${f} — ${r}`).join("\n") +
          "\n",
      );
    }

    expect(allKnown.length).toBeGreaterThanOrEqual(0); // always passes
  });

  it("classifies lane-D deprecation hotspots as migrate-now vs compatibility-only", () => {
    expect(BEADS_RUST_KNOWN_VIOLATIONS["cli/commands/bead.ts"]).toBeUndefined();

    expect(BEADS_RUST_KNOWN_VIOLATIONS["cli/commands/plan.ts"]).toBeUndefined();

    expect(BEADS_RUST_KNOWN_VIOLATIONS["orchestrator/task-ordering.ts"]).toBeUndefined();
    expect(BEADS_RUST_KNOWN_VIOLATIONS["lib/task-client-factory.ts"]).toBeUndefined();
  });
});
