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
 *   src/orchestrator/dispatcher.ts   — The designated "fallback" instantiation
 *                                      point during the BeadsRustClient deprecation
 *                                      transition. Dispatcher owns the concrete
 *                                      client selection logic.
 *
 * --- Known Violations (TODO: migrate — see TRD-014) ---
 * The following files currently import BeadsRustClient directly and must be
 * migrated to use the ITaskClient interface or a higher-level factory.
 * Each entry links to the tracking issue and describes the required change.
 *
 * CLI commands (should receive ITaskClient via dispatcher/factory):
 *   src/cli/commands/bead.ts           — factory fn returns BeadsRustClient
 *   src/cli/commands/dashboard.ts      — direct instantiation
 *   src/cli/commands/doctor.ts         — health-check instantiation
 *   src/cli/commands/merge.ts          — factory fn returns BeadsRustClient
 *   src/cli/commands/monitor.ts        — direct instantiation
 *   src/cli/commands/plan.ts           — factory fn returns BeadsRustClient
 *   src/cli/commands/pr.ts             — direct instantiation
 *   src/cli/commands/purge-zombie-runs.ts — direct instantiation
 *   src/cli/commands/reset.ts          — direct instantiation
 *   src/cli/commands/retry.ts          — direct instantiation + param type
 *   src/cli/commands/run.ts            — direct import
 *   src/cli/commands/sentinel.ts       — direct instantiation
 *   src/cli/commands/sling.ts          — conditional instantiation
 *   src/cli/commands/status.ts         — direct instantiation
 *
 * Orchestrator (should use ITaskClient interface):
 *   src/orchestrator/agent-worker.ts   — direct instantiation in merge path
 *   src/orchestrator/sentinel.ts       — import type for constructor parameter
 *   src/orchestrator/sling-executor.ts — import type for multiple function params
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
  // Dispatcher — the sole designated fallback instantiation point
  "orchestrator/dispatcher.ts",
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
  // Factory function `getBeadsClient()` returns concrete BeadsRustClient.
  // Needs: return ITaskClient and update call-sites to use the interface.
  "cli/commands/bead.ts":
    "TRD-014: getBeadsClient() return type → ITaskClient",

  // Direct instantiation for dashboard display.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/dashboard.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Doctor health-check imports BeadsRustClient to test binary availability.
  // Needs: extract binary check to a dedicated health-check helper or use ITaskClient.
  "cli/commands/doctor.ts":
    "TRD-014: health-check instantiation → use ITaskClient or binary helper",

  // Factory function `getMergeTaskClient()` returns concrete BeadsRustClient.
  // Needs: return ITaskClient and update call-sites to use the interface.
  "cli/commands/merge.ts":
    "TRD-014: getMergeTaskClient() return type → ITaskClient",

  // Direct instantiation for monitor loop.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/monitor.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Factory function `getPlanTaskClient()` returns concrete BeadsRustClient.
  // Needs: return ITaskClient and update call-sites to use the interface.
  "cli/commands/plan.ts":
    "TRD-014: getPlanTaskClient() return type → ITaskClient",

  // Direct instantiation for PR listing.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/pr.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Direct instantiation for zombie-run cleanup.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/purge-zombie-runs.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Direct instantiation in reset/mismatch-fix logic.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/reset.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Direct instantiation + used as parameter type for retry logic.
  // Needs: switch parameter type to ITaskClient and inject.
  "cli/commands/retry.ts":
    "TRD-014: parameter type + instantiation → ITaskClient",

  // Direct import used in run command (dispatcher wires it up).
  // Needs: remove direct import; receive ITaskClient from dispatcher context.
  "cli/commands/run.ts":
    "TRD-014: direct import → receive ITaskClient from dispatcher",

  // Direct instantiation inside sentinel command.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/sentinel.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // Conditional instantiation for sling workflow.
  // Needs: receive ITaskClient; sling-executor already typed via its own param types.
  "cli/commands/sling.ts":
    "TRD-014: conditional instantiation → inject ITaskClient",

  // Direct instantiation for status display.
  // Needs: receive ITaskClient from a factory/DI rather than importing directly.
  "cli/commands/status.ts":
    "TRD-014: direct instantiation → inject ITaskClient",

  // ── Orchestrator ──────────────────────────────────────────────────────────
  // Direct instantiation in merge-queue enqueue path of agent-worker.
  // Needs: use the ITaskClient already threaded through the pipeline context.
  "orchestrator/agent-worker.ts":
    "TRD-014: direct instantiation in merge path → use injected ITaskClient",

  // `import type` for constructor parameter typing in SeedWatcher.
  // Needs: change parameter type to ITaskClient interface.
  "orchestrator/sentinel.ts":
    "TRD-014: parameter type → ITaskClient",

  // Multiple `import type` usages for function parameter types in sling-executor.
  // Needs: change all parameter types from BeadsRustClient to ITaskClient.
  "orchestrator/sling-executor.ts":
    "TRD-014: function parameter types → ITaskClient",
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

        // Only flag import statements (not generic references inside code)
        if (!trimmed.includes(IMPORT_PATTERN)) continue;

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

    // Emit a console note so CI logs show the remaining migration backlog
    if (allKnown.length > 0) {
      console.log(
        `\n[TRD-014] ${allKnown.length} known BeadsRustClient violation(s) remaining to migrate to ITaskClient:\n` +
          allKnown.map(([f, r]) => `  • src/${f} — ${r}`).join("\n") +
          "\n",
      );
    } else {
      console.log(
        "\n[TRD-014] All BeadsRustClient violations have been migrated. " +
          "BeadsRustClient is now only used in lib/beads-rust.ts and orchestrator/dispatcher.ts.\n",
      );
    }

    expect(allKnown.length).toBeGreaterThanOrEqual(0); // always passes
  });
});
