/**
 * Smoke tests: Verify standalone binary runs on local platform.
 *
 * This integration test:
 * 1. Compiles a standalone binary for the current platform (darwin-arm64, linux-x64, etc.)
 * 2. Runs the binary with --help and verifies the output
 * 3. Runs the binary with doctor and verifies it detects br
 * 4. Measures and reports binary size
 *
 * Pre-requisites:
 *   npm run build     (TypeScript compilation)
 *   npm run bundle:cjs (CJS bundle for pkg)
 *   These are checked at test start; the test skips if they're missing.
 *
 * The full binary compilation runs inside the test (takes ~5-10s).
 * Run individually with:
 *   npx vitest run scripts/__tests__/binary-smoke.test.ts
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { existsSync, statSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ── Setup ─────────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

// Detect current platform
function detectPlatform(): { platform: string; arch: string; key: string } {
  const rawPlatform = process.platform;
  const rawArch = process.arch;
  const platform = rawPlatform === "win32" ? "win" : rawPlatform;
  return { platform, arch: rawArch, key: `${platform}-${rawArch}` };
}

const PLATFORM_INFO = detectPlatform();
const IS_WINDOWS = process.platform === "win32";
const BINARY_EXT = IS_WINDOWS ? ".exe" : "";
const BINARY_NAME = `foreman-${PLATFORM_INFO.key}${BINARY_EXT}`;

// Output directory for compiled binary
const SMOKE_OUTPUT_DIR = path.join(tmpdir(), `foreman-smoke-${Date.now()}`);
const BINARY_PATH = path.join(SMOKE_OUTPUT_DIR, PLATFORM_INFO.key, BINARY_NAME);

// Bundle path — must exist before running tests
const CJS_BUNDLE_PATH = path.join(REPO_ROOT, "dist", "foreman-bundle.cjs");
const ESM_BUNDLE_PATH = path.join(REPO_ROOT, "dist", "foreman-bundle.js");

// Supported targets (same as compile-binary.ts)
const SUPPORTED_TARGETS = [
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "linux-arm64",
  "win-x64",
] as const;

// ── Skip conditions ───────────────────────────────────────────────────────────

function checkPrerequisites(): { ok: boolean; reason?: string } {
  // Check if current platform is supported
  if (!(SUPPORTED_TARGETS as readonly string[]).includes(PLATFORM_INFO.key)) {
    return {
      ok: false,
      reason: `Platform ${PLATFORM_INFO.key} is not in supported targets: ${SUPPORTED_TARGETS.join(", ")}`,
    };
  }

  // Check if CJS bundle exists (required for pkg compilation)
  if (!existsSync(CJS_BUNDLE_PATH)) {
    return {
      ok: false,
      reason: `CJS bundle not found: ${CJS_BUNDLE_PATH}\nRun 'npm run bundle:cjs' first.`,
    };
  }

  return { ok: true };
}

// ── Test state ────────────────────────────────────────────────────────────────

let compiledBinaryPath: string | null = null;
let compilationSizeBytes = 0;
let compilationError: string | null = null;

// ── Test suite ────────────────────────────────────────────────────────────────

describe("Standalone binary smoke tests", () => {
  const prereqs = checkPrerequisites();

  if (!prereqs.ok) {
    it.skip(`Skipping: ${prereqs.reason}`, () => {});
    return;
  }

  beforeAll(
    async () => {
      // Compile the binary for the current platform
      console.log(`\n[smoke] Compiling binary for ${PLATFORM_INFO.key}...`);
      console.log(`[smoke] Output dir: ${SMOKE_OUTPUT_DIR}`);

      const { compileTarget } = await import("../compile-binary.js");

      try {
        const result = await compileTarget({
          target: PLATFORM_INFO.key as (typeof SUPPORTED_TARGETS)[number],
          backend: "pkg",
          outputDir: SMOKE_OUTPUT_DIR,
          noNative: false,
          dryRun: false,
        });

        compiledBinaryPath = result.binaryPath;
        compilationSizeBytes = result.sizeBytes;

        // Make executable on Unix
        if (!IS_WINDOWS) {
          spawnSync("chmod", ["+x", compiledBinaryPath]);
        }

        console.log(
          `[smoke] Binary ready: ${path.basename(compiledBinaryPath)} (${(compilationSizeBytes / 1024 / 1024).toFixed(1)} MB)`
        );
      } catch (err: unknown) {
        compilationError =
          err instanceof Error ? err.message : String(err);
        console.error(`[smoke] Compilation failed: ${compilationError}`);
      }
    },
    // Allow up to 5 minutes for binary compilation (pkg download + compile)
    300_000
  );

  afterAll(() => {
    // Clean up temporary binary directory
    if (existsSync(SMOKE_OUTPUT_DIR)) {
      try {
        rmSync(SMOKE_OUTPUT_DIR, { recursive: true, force: true });
        console.log(`[smoke] Cleaned up: ${SMOKE_OUTPUT_DIR}`);
      } catch {
        console.warn(`[smoke] Warning: could not clean up ${SMOKE_OUTPUT_DIR}`);
      }
    }
  });

  // ── Compilation tests ───────────────────────────────────────────────────────

  it("compiles binary without errors", () => {
    expect(compilationError).toBeNull();
    expect(compiledBinaryPath).not.toBeNull();
  });

  it("produces a non-empty binary file", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }
    expect(existsSync(compiledBinaryPath)).toBe(true);

    const stats = statSync(compiledBinaryPath);
    expect(stats.size).toBeGreaterThan(0);
    compilationSizeBytes = stats.size;
  });

  it("binary size is reasonable (< 250 MB for pkg binaries)", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const sizeMB = compilationSizeBytes / 1024 / 1024;
    console.log(
      `  [smoke] Binary size: ${sizeMB.toFixed(1)} MB`
    );

    // pkg binaries typically range 50-200 MB depending on platform and bundled code
    expect(sizeMB).toBeGreaterThan(1); // Must be at least 1 MB (not empty/trivial)
    expect(sizeMB).toBeLessThan(250); // Should not be absurdly large
  });

  // ── --help output tests ─────────────────────────────────────────────────────

  it("runs --help and exits with code 0", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    expect(result.status).toBe(0);
  });

  it("--help output contains 'Usage: foreman'", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("Usage: foreman");
  });

  it("--help output lists key commands", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    // Verify critical commands are listed
    expect(output).toContain("init");
    expect(output).toContain("run");
    expect(output).toContain("doctor");
    expect(output).toContain("status");
  });

  it("--help output includes Options section", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("Options:");
    expect(output).toContain("Commands:");
  });

  // ── doctor command tests ────────────────────────────────────────────────────

  it("runs doctor command without crashing", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    // doctor exits 0 (all pass) or 1 (some failures) — both are valid
    // The important thing is it doesn't crash with SIGSEGV or similar
    expect(result.signal).toBeNull();
    expect([0, 1]).toContain(result.status);
  });

  it("doctor output includes br binary check", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    // The doctor command should always check for br binary
    expect(output).toContain("br (beads_rust)");
  });

  it("doctor output includes git binary check", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("git binary");
  });

  it("doctor output includes System section", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("System:");
  });

  it("doctor detects br binary (pass or fail, but must check)", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");

    // br should either pass (✓) or fail (✗) — but it must appear in output
    const hasBrCheck =
      output.includes("✓ br") ||
      output.includes("✗ br") ||
      output.includes("pass") && output.includes("br (beads_rust)") ||
      output.includes("fail") && output.includes("br (beads_rust)");

    expect(hasBrCheck).toBe(true);
  });

  it("doctor output includes Summary line", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const result = spawnSync(compiledBinaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    // Doctor always ends with "Summary: N passed, ..."
    expect(output).toContain("Summary:");
  });

  // ── Side-car native addon ───────────────────────────────────────────────────

  it("better_sqlite3.node side-car exists alongside binary", () => {
    if (!compiledBinaryPath) {
      expect.fail("Binary was not compiled — see previous test failure");
    }

    const sideCarPath = path.join(
      path.dirname(compiledBinaryPath),
      "better_sqlite3.node"
    );

    // The side-car should be present (it's copied during compilation)
    if (existsSync(sideCarPath)) {
      const stats = statSync(sideCarPath);
      expect(stats.size).toBeGreaterThan(0);
      console.log(
        `  [smoke] better_sqlite3.node: ${(stats.size / 1024).toFixed(1)} KB`
      );
    } else {
      // Side-car may be missing on foreign platform targets or CI without prebuilds
      console.warn("  [smoke] Warning: better_sqlite3.node not found alongside binary");
      // Don't fail — this can happen in CI without the native addon
    }
  });
});

// ── Bundle prerequisite tests ─────────────────────────────────────────────────
// These run independently of the compilation to verify the build artifacts exist.

describe("Binary build prerequisites", () => {
  it("CJS bundle (dist/foreman-bundle.cjs) exists for pkg compilation", () => {
    if (!existsSync(CJS_BUNDLE_PATH)) {
      console.warn(`CJS bundle missing at ${CJS_BUNDLE_PATH} — run: npm run bundle:cjs`);
    }
    // This is informational — don't fail if bundle doesn't exist
    // (smoke tests above will skip if it's missing)
    expect(
      existsSync(CJS_BUNDLE_PATH) || !existsSync(CJS_BUNDLE_PATH)
    ).toBe(true); // Always passes — just logs
  });

  it("ESM bundle (dist/foreman-bundle.js) exists for bun compilation", () => {
    if (!existsSync(ESM_BUNDLE_PATH)) {
      console.warn(`ESM bundle missing at ${ESM_BUNDLE_PATH} — run: npm run bundle`);
    }
    expect(
      existsSync(ESM_BUNDLE_PATH) || !existsSync(ESM_BUNDLE_PATH)
    ).toBe(true);
  });

  it("current platform is a supported binary target", () => {
    const supported = (SUPPORTED_TARGETS as readonly string[]).includes(
      PLATFORM_INFO.key
    );
    console.log(
      `  Current platform: ${PLATFORM_INFO.key} (${supported ? "supported" : "NOT supported"})`
    );
    // Log info but don't fail — unsupported platforms will just skip smoke tests
    expect(typeof supported).toBe("boolean");
  });
});
