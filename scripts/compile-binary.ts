/**
 * Binary compilation script for foreman CLI.
 *
 * Takes the esbuild bundle (dist/foreman-bundle.js) and compiles it into
 * standalone executables for the following platform/arch combinations:
 *   - darwin-arm64
 *   - darwin-x64
 *   - linux-x64
 *   - linux-arm64
 *   - win-x64
 *
 * ## Backend Evaluation
 *
 * ### pkg (default)
 *   ✅ Mature, widely used, cross-compilation targets supported
 *   ✅ Proven native addon (.node) support via --path or asset snapshotting
 *   ✅ No changes to runtime code needed
 *   ❌ Larger binary size (~80–120 MB)
 *   ❌ Slower compilation than bun
 *
 * ### bun compile
 *   ✅ Very fast compilation, smaller binaries (~40–60 MB initial)
 *   ✅ Single binary, no wrapper scripts needed
 *   ⚠️ Native addon (.node) support requires --external and side-car pattern
 *   ❌ bun binary must be installed on build machine (not in node_modules)
 *   ❌ Less battle-tested for complex CLIs with native addons
 *
 * ### Node.js SEA (Single Executable Application)
 *   ✅ Official Node.js solution since v20
 *   ❌ Cannot require() arbitrary external modules at runtime
 *   ❌ No native addon (.node) support inside the SEA blob
 *   ❌ Requires wrapping with postject; complex cross-platform tooling
 *   ➡️ Not suitable for better-sqlite3 — deferred to future evaluation
 *
 * ## Decision
 * Use **pkg** as the default backend. It handles better_sqlite3.node via the
 * --path flag (side-car placement) and cross-platform targets are well tested.
 * A --backend=bun flag is supported for experimental use.
 *
 * ## Native Addon Strategy
 * better_sqlite3.node cannot be bundled inside a binary (it is a native
 * shared library). Both backends use the "side-car" pattern:
 *   - The .node file is placed alongside the binary in the output directory
 *   - The runtime detects it via resolveBundledNativeBinding() in store.ts
 *   - Output dir per target: dist/binaries/{platform}-{arch}/
 *
 * ## Cross-Platform Note
 * better_sqlite3.node is platform-specific. This script can only embed the
 * .node file for the current host platform unless prebuilt binaries for
 * foreign platforms are present in scripts/prebuilds/{platform}-{arch}/.
 * GitHub Actions matrix builds are the recommended approach for full coverage.
 *
 * ## Usage
 *   tsx scripts/compile-binary.ts [options]
 *
 * Options:
 *   --target <platform-arch>  Single target (e.g. darwin-arm64)
 *   --all                     Compile all 5 supported targets
 *   --backend <pkg|bun>       Compilation backend (default: pkg)
 *   --output-dir <dir>        Output directory (default: dist/binaries)
 *   --no-native               Skip native addon copy (for testing)
 *   --dry-run                 Print commands without executing
 */

import { execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  copyFileSync,
  statSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getBetterSqlite3NodePath, detectPlatform } from "./native-addon-utils.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

/** All supported compilation targets */
export const SUPPORTED_TARGETS = [
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "linux-arm64",
  "win-x64",
] as const;

export type SupportedTarget = (typeof SUPPORTED_TARGETS)[number];

/** pkg target triple mapping: foreman target → pkg target string */
const PKG_TARGET_MAP: Record<SupportedTarget, string> = {
  "darwin-arm64": "node20-macos-arm64",
  "darwin-x64": "node20-macos-x64",
  "linux-x64": "node20-linux-x64",
  "linux-arm64": "node20-linux-arm64",
  "win-x64": "node20-win-x64",
};

/** bun compile target triple mapping */
const BUN_TARGET_MAP: Record<SupportedTarget, string> = {
  "darwin-arm64": "bun-macos-arm64",
  "darwin-x64": "bun-macos-x64",
  "linux-x64": "bun-linux-x64",
  "linux-arm64": "bun-linux-arm64",
  "win-x64": "bun-windows-x64",
};

/** Platforms that need a .exe extension */
const WINDOWS_PLATFORMS = new Set(["win"]);

// ── Types ─────────────────────────────────────────────────────────────────────

export type CompilationBackend = "pkg" | "bun";

export interface CompileOptions {
  /** Target platform-arch combination */
  target: SupportedTarget;
  /** Compilation backend */
  backend: CompilationBackend;
  /** Root output directory (binaries go in <outputDir>/<target>/) */
  outputDir: string;
  /** Skip native addon copy step */
  noNative: boolean;
  /** Print commands without running them */
  dryRun: boolean;
  /**
   * Override the bundle path (default: dist/foreman-bundle.js).
   * Useful for tests that need to control bundle existence.
   */
  bundlePath?: string;
}

export interface CompileResult {
  target: SupportedTarget;
  binaryPath: string;
  nativeAddonPath: string | null;
  sizeBytes: number;
  durationMs: number;
}

// ── Validation ────────────────────────────────────────────────────────────────

/**
 * Validate that a given string is a supported target.
 */
export function validateTarget(target: string): target is SupportedTarget {
  return (SUPPORTED_TARGETS as readonly string[]).includes(target);
}

/**
 * Derive the output binary filename for a given target.
 * Windows targets get .exe extension; others have no extension.
 */
export function getBinaryName(target: SupportedTarget): string {
  const [platform] = target.split("-");
  const ext = WINDOWS_PLATFORMS.has(platform) ? ".exe" : "";
  return `foreman-${target}${ext}`;
}

/**
 * Locate better_sqlite3.node for the given target.
 *
 * Search order:
 *  1. scripts/prebuilds/{target}/better_sqlite3.node  (pre-downloaded cross-platform)
 *  2. scripts/prebuilds/{target}/node.napi.node        (alternate name)
 *  3. node_modules/.../better_sqlite3.node             (current host platform only)
 *
 * @returns Absolute path to the .node file, or null if not found.
 */
export function findNativeAddon(target: SupportedTarget): string | null {
  // Check prebuilds directory first (cross-platform binaries)
  const prebuildsDir = path.join(REPO_ROOT, "scripts", "prebuilds", target);

  const prebuildPrimary = path.join(prebuildsDir, "better_sqlite3.node");
  if (existsSync(prebuildPrimary)) {
    return prebuildPrimary;
  }

  const prebuildAlt = path.join(prebuildsDir, "node.napi.node");
  if (existsSync(prebuildAlt)) {
    return prebuildAlt;
  }

  // Fall back to node_modules (only works for current host platform)
  const { key: hostKey } = detectPlatform();
  if (hostKey === target) {
    return getBetterSqlite3NodePath(REPO_ROOT);
  }

  return null;
}

// ── pkg Backend ───────────────────────────────────────────────────────────────

/**
 * Compile a binary for a single target using pkg.
 *
 * pkg wraps the bundle + Node.js runtime into a self-contained executable.
 * The better_sqlite3.node file is placed as a side-car in the output dir;
 * the runtime detects it via resolveBundledNativeBinding().
 */
function compilePkg(
  bundlePath: string,
  binaryPath: string,
  target: SupportedTarget,
  dryRun: boolean
): void {
  const pkgTarget = PKG_TARGET_MAP[target];

  // Build the pkg command
  // --path is used to allow reading the .node file from disk at runtime
  const cmd = [
    "npx",
    "--yes",
    "pkg",
    bundlePath,
    "--target",
    pkgTarget,
    "--output",
    binaryPath,
    // Allow reading files relative to the binary's directory at runtime
    "--path",
    path.dirname(binaryPath),
    // Use node20 for maximum compatibility
    "--no-bytecode",
    "--public",
    "--public-packages",
    "*",
  ].join(" ");

  console.log(`  [pkg] Running: ${cmd}`);

  if (!dryRun) {
    execSync(cmd, {
      cwd: REPO_ROOT,
      stdio: "inherit",
      env: { ...process.env },
    });
  }
}

// ── bun Backend ───────────────────────────────────────────────────────────────

/**
 * Compile a binary using bun compile.
 *
 * bun compile creates a self-contained binary that embeds bun's runtime.
 * Native addons (.node files) must be side-car files — they cannot be embedded.
 * The bundle must be a CJS or ESM module that bun understands.
 *
 * NOTE: bun compile works best with CJS bundles; our ESM bundle may need
 * adjustment. This backend is experimental.
 */
function compileBun(
  bundlePath: string,
  binaryPath: string,
  target: SupportedTarget,
  dryRun: boolean
): void {
  const bunTarget = BUN_TARGET_MAP[target];

  // bun compile embeds the entrypoint and all statically-importable modules.
  // better-sqlite3 is externalized in the esbuild bundle so it will attempt
  // to require() it at runtime — bun will look for it in node_modules or
  // relative to the binary.
  const cmd = [
    "bun",
    "build",
    bundlePath,
    "--compile",
    "--target",
    bunTarget,
    "--outfile",
    binaryPath,
    // Mark better-sqlite3 as external so bun doesn't try to bundle it
    "--external",
    "better-sqlite3",
  ].join(" ");

  console.log(`  [bun] Running: ${cmd}`);

  if (!dryRun) {
    execSync(cmd, {
      cwd: REPO_ROOT,
      stdio: "inherit",
      env: { ...process.env },
    });
  }
}

// ── Main Compilation Function ─────────────────────────────────────────────────

/**
 * Compile a standalone binary for a single target.
 *
 * This function:
 * 1. Validates the bundle exists
 * 2. Creates the output directory
 * 3. Invokes the chosen backend (pkg or bun)
 * 4. Copies better_sqlite3.node alongside the binary (side-car pattern)
 * 5. Validates the output binary exists and is non-empty
 *
 * @throws Error if bundle is missing, compilation fails, or output is missing.
 */
export async function compileTarget(options: CompileOptions): Promise<CompileResult> {
  const { target, backend, outputDir, noNative, dryRun } = options;
  const startTime = Date.now();

  const bundlePath =
    options.bundlePath ?? path.join(REPO_ROOT, "dist", "foreman-bundle.js");
  const targetDir = path.join(outputDir, target);
  const binaryName = getBinaryName(target);
  const binaryPath = path.join(targetDir, binaryName);

  console.log(`\n━━━ Compiling ${target} (${backend}) ━━━`);

  // ── Validate bundle exists ────────────────────────────────────────────────
  if (!existsSync(bundlePath)) {
    throw new Error(
      `Bundle not found: ${bundlePath}\n` +
        "Run 'npm run bundle' first to generate dist/foreman-bundle.js"
    );
  }

  // ── Create output directory ───────────────────────────────────────────────
  if (!dryRun) {
    mkdirSync(targetDir, { recursive: true });
  } else {
    console.log(`  [dry-run] Would create: ${targetDir}`);
  }

  // ── Compile ───────────────────────────────────────────────────────────────
  if (backend === "pkg") {
    compilePkg(bundlePath, binaryPath, target, dryRun);
  } else if (backend === "bun") {
    compileBun(bundlePath, binaryPath, target, dryRun);
  } else {
    throw new Error(`Unknown backend: ${String(backend)}`);
  }

  // ── Copy native addon (side-car) ──────────────────────────────────────────
  let nativeAddonPath: string | null = null;

  if (!noNative) {
    const sourcePath = findNativeAddon(target);

    if (!sourcePath) {
      const { key: hostKey } = detectPlatform();
      const hint =
        hostKey !== target
          ? `\nFor cross-compilation, provide prebuilt binaries in scripts/prebuilds/${target}/`
          : "\nRun 'npm install' to fetch the prebuilt binary for the current platform.";

      // Warn rather than fail — the binary may still work if node_modules is present
      console.warn(
        `\n⚠️  WARNING: Could not find better_sqlite3.node for ${target}.` +
          `\n   The binary will require better-sqlite3 from node_modules at runtime.` +
          hint
      );
    } else {
      const destPath = path.join(targetDir, "better_sqlite3.node");
      if (!dryRun) {
        copyFileSync(sourcePath, destPath);
        const sizeKB = (statSync(destPath).size / 1024).toFixed(1);
        console.log(
          `  ✓ Copied better_sqlite3.node (${sizeKB} KB) → ${path.relative(REPO_ROOT, destPath)}`
        );
      } else {
        console.log(
          `  [dry-run] Would copy: ${sourcePath} → ${destPath}`
        );
      }
      nativeAddonPath = destPath;
    }
  }

  // ── Validate output ───────────────────────────────────────────────────────
  let sizeBytes = 0;

  if (!dryRun) {
    if (!existsSync(binaryPath)) {
      throw new Error(
        `Compilation succeeded but output binary not found: ${binaryPath}`
      );
    }

    const stats = statSync(binaryPath);
    sizeBytes = stats.size;

    if (sizeBytes === 0) {
      throw new Error(`Output binary is empty: ${binaryPath}`);
    }

    const sizeMB = (sizeBytes / 1024 / 1024).toFixed(1);
    console.log(
      `  ✓ Binary: ${path.relative(REPO_ROOT, binaryPath)} (${sizeMB} MB)`
    );
  } else {
    console.log(`  [dry-run] Would produce: ${path.relative(REPO_ROOT, binaryPath)}`);
  }

  const durationMs = Date.now() - startTime;
  console.log(`  ✓ Done in ${(durationMs / 1000).toFixed(1)}s`);

  return {
    target,
    binaryPath,
    nativeAddonPath,
    sizeBytes,
    durationMs,
  };
}

// ── CLI Argument Parsing ──────────────────────────────────────────────────────

interface CliArgs {
  targets: SupportedTarget[];
  backend: CompilationBackend;
  outputDir: string;
  noNative: boolean;
  dryRun: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  const args = argv.slice(2); // Remove node/tsx binary paths

  let targets: SupportedTarget[] = [];
  let backend: CompilationBackend = "pkg";
  let outputDir = path.join(REPO_ROOT, "dist", "binaries");
  let noNative = false;
  let dryRun = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === "--all") {
      targets = [...SUPPORTED_TARGETS];
    } else if (arg === "--target" || arg === "-t") {
      const val = args[++i];
      if (!val) {
        throw new Error("--target requires a value");
      }
      if (!validateTarget(val)) {
        throw new Error(
          `Invalid target: "${val}"\nSupported targets: ${SUPPORTED_TARGETS.join(", ")}`
        );
      }
      targets.push(val);
    } else if (arg === "--backend" || arg === "-b") {
      const val = args[++i];
      if (val !== "pkg" && val !== "bun") {
        throw new Error(`Invalid backend: "${val}". Must be "pkg" or "bun"`);
      }
      backend = val;
    } else if (arg === "--output-dir" || arg === "-o") {
      outputDir = path.resolve(args[++i] ?? "");
    } else if (arg === "--no-native") {
      noNative = true;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (targets.length === 0) {
    throw new Error(
      "No targets specified. Use --all or --target <platform-arch>.\n" +
        "Run with --help for usage."
    );
  }

  return { targets, backend, outputDir, noNative, dryRun };
}

function printHelp(): void {
  console.log(`
Usage: tsx scripts/compile-binary.ts [options]

Options:
  --all                   Compile all 5 supported targets
  --target <platform-arch>  Single target to compile (repeatable)
  --backend <pkg|bun>     Compilation backend (default: pkg)
  --output-dir <dir>      Output directory (default: dist/binaries)
  --no-native             Skip native addon copy step
  --dry-run               Print commands without executing
  --help                  Show this help message

Supported targets:
  ${SUPPORTED_TARGETS.join("\n  ")}

Examples:
  tsx scripts/compile-binary.ts --all
  tsx scripts/compile-binary.ts --target darwin-arm64
  tsx scripts/compile-binary.ts --target linux-x64 --backend bun
  tsx scripts/compile-binary.ts --all --dry-run

Output:
  dist/binaries/{platform}-{arch}/foreman-{platform}-{arch}[.exe]
  dist/binaries/{platform}-{arch}/better_sqlite3.node

Native Addon (better_sqlite3.node):
  For the current host platform, the addon is copied from node_modules.
  For cross-compilation, place prebuilt binaries in:
    scripts/prebuilds/{platform}-{arch}/better_sqlite3.node
  (These are provided by task bd-n801 or downloaded from GitHub Releases.)
`);
}

// ── Entry Point ───────────────────────────────────────────────────────────────

/**
 * Main entry point — parse CLI args and compile the requested targets.
 */
async function main(): Promise<void> {
  console.log("═══ Foreman Binary Compiler ═══\n");

  let cliArgs: CliArgs;
  try {
    cliArgs = parseArgs(process.argv);
  } catch (err) {
    console.error(`Error: ${String(err instanceof Error ? err.message : err)}`);
    process.exit(1);
  }

  const { targets, backend, outputDir, noNative, dryRun } = cliArgs;

  console.log(`Backend:    ${backend}`);
  console.log(`Output dir: ${outputDir}`);
  console.log(`Targets:    ${targets.join(", ")}`);
  if (noNative) console.log("⚠️  --no-native: skipping better_sqlite3.node copy");
  if (dryRun) console.log("🔍 --dry-run: commands will be printed but not executed\n");

  const results: CompileResult[] = [];
  const failures: Array<{ target: SupportedTarget; error: string }> = [];

  for (const target of targets) {
    try {
      const result = await compileTarget({
        target,
        backend,
        outputDir,
        noNative,
        dryRun,
      });
      results.push(result);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`\n✗ Failed to compile ${target}: ${message}`);
      failures.push({ target, error: message });
    }
  }

  // ── Summary ─────────────────────────────────────────────────────────────────
  console.log("\n═══ Compilation Summary ═══");

  if (results.length > 0) {
    console.log("\n✓ Succeeded:");
    for (const r of results) {
      const sizeMB = dryRun ? "N/A" : `${(r.sizeBytes / 1024 / 1024).toFixed(1)} MB`;
      const duration = `${(r.durationMs / 1000).toFixed(1)}s`;
      const rel = path.relative(REPO_ROOT, r.binaryPath);
      console.log(`  ${r.target.padEnd(15)} ${rel}  (${sizeMB}, ${duration})`);
    }
  }

  if (failures.length > 0) {
    console.log("\n✗ Failed:");
    for (const f of failures) {
      console.log(`  ${f.target}: ${f.error}`);
    }
    process.exit(1);
  }

  console.log("\nDone.");
}

// Only run main() when this file is executed directly
const __currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__currentFile)) {
  main().catch((err: unknown) => {
    console.error("Unexpected error:", err);
    process.exit(1);
  });
}
