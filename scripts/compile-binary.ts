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
 *   ✅ No changes to runtime code needed
 *   ❌ Larger binary size (~80–120 MB)
 *   ❌ Slower compilation than bun
 *
 * ### bun compile
 *   ✅ Very fast compilation, smaller binaries (~40–60 MB initial)
 *   ✅ Single binary, no wrapper scripts needed
 *   ❌ bun binary must be installed on build machine (not in node_modules)
 *   ❌ Less battle-tested for complex CLIs
 *
 * ### Node.js SEA (Single Executable Application)
 *   ✅ Official Node.js solution since v20
 *   ❌ Cannot require() arbitrary external modules at runtime
 *   ❌ Requires wrapping with postject; complex cross-platform tooling
 *
 * ## Decision
 * Use **pkg** as the default backend. A --backend=bun flag is supported for experimental use.
 *
 * ## Usage
 *   tsx scripts/compile-binary.ts [options]
 *
 * Options:
 *   --target <platform-arch>  Single target (e.g. darwin-arm64)
 *   --all                     Compile all 5 supported targets
 *   --backend <pkg|bun>       Compilation backend (default: pkg)
 *   --output-dir <dir>        Output directory (default: dist/binaries)
 *   --dry-run                 Print commands without executing
 */

import { execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  statSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
  /** Print commands without running them */
  dryRun: boolean;
}

export interface CompileResult {
  target: SupportedTarget;
  binaryPath: string;
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

// ── pkg Backend ───────────────────────────────────────────────────────────────

/**
 * Compile a binary for a single target using pkg.
 *
 * pkg wraps the bundle + Node.js runtime into a self-contained executable.
 */
async function compilePkg(
  bundlePath: string,
  binaryPath: string,
  target: SupportedTarget,
  dryRun: boolean
): Promise<void> {
  const pkgTarget = PKG_TARGET_MAP[target];

  // Write a temporary pkg config that includes package.json as an asset.
  // The pi-coding-agent bundled into the CJS bundle walks up from __dirname
  // (which is `dist/` in the snapshot) looking for a package.json to read
  // version/config info. Without it, the binary crashes with ENOENT.
  //
  // Strategy: Create a stub dist/package.json with pi-coding-agent metadata
  // so the snapshot resolver can find it at the bundle directory path.
  const distPkgJsonPath = path.join(REPO_ROOT, "dist", "package.json");
  const piPkgJsonPath = path.join(
    REPO_ROOT, "node_modules", "@mariozechner", "pi-coding-agent", "package.json"
  );

  if (!dryRun) {
    const { mkdirSync: mkdir2, writeFileSync: write2, readFileSync: read2 } = await import("node:fs");

    // Read pi-coding-agent's package.json to get its piConfig/version metadata
    let piPkg: Record<string, unknown> = {};
    try {
      piPkg = JSON.parse(read2(piPkgJsonPath, "utf-8")) as Record<string, unknown>;
    } catch {
      // If not found, use defaults that match pi-coding-agent's built-in defaults
    }

    // Write a stub dist/package.json for the snapshot to find
    const distPkg = {
      name: "foreman",
      version: (piPkg.version as string | undefined) ?? "0.0.0",
      piConfig: piPkg.piConfig ?? { name: "pi", configDir: ".pi" },
    };
    mkdir2(path.dirname(distPkgJsonPath), { recursive: true });
    write2(distPkgJsonPath, JSON.stringify(distPkg, null, 2));
  }

  // No separate config file needed — the root package.json contains:
  // { "pkg": { "assets": ["dist/package.json"] } }
  // This tells @yao-pkg/pkg to include dist/package.json in the snapshot.
  // The dist/package.json stub is created above in the "create stub dist/package.json" step.

  // Build the pkg command using spawnSync to avoid shell glob expansion.
  // Use @yao-pkg/pkg (v6+) which supports node20+ targets.
  // The original pkg@5.x is limited to node18 and below.
  // NOTE: --path is not a valid pkg flag; native addons are handled as side-cars.
  // --public-packages "*" must not be shell-expanded, hence array form.
  const cmdArgs = [
    "--yes",
    "@yao-pkg/pkg",
    bundlePath,
    "--target",
    pkgTarget,
    "--output",
    binaryPath,
    // Use node20 for maximum compatibility
    "--no-bytecode",
    "--public",
    "--public-packages",
    "*",  // passed as a literal string via array (no shell expansion)
  ];

  console.log(`  [pkg] Running: npx ${cmdArgs.join(" ")}`);

  if (!dryRun) {
    const { spawnSync } = await import("node:child_process");
    const result = spawnSync("npx", cmdArgs, {
      cwd: REPO_ROOT,
      stdio: "inherit",
      env: { ...process.env },
    });
    if (result.status !== 0) {
      throw new Error(
        `pkg compilation failed for ${target} (exit code ${result.status ?? "unknown"})`
      );
    }
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
  const cmd = [
    "bun",
    "build",
    bundlePath,
    "--compile",
    "--target",
    bunTarget,
    "--outfile",
    binaryPath,
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
 * 4. Validates the output binary exists and is non-empty
 *
 * @throws Error if bundle is missing, compilation fails, or output is missing.
 */
export async function compileTarget(options: CompileOptions): Promise<CompileResult> {
  const { target, backend, outputDir, dryRun } = options;
  const startTime = Date.now();

  // pkg requires a CJS bundle (ESM bundles are incompatible with pkg's bootstrap).
  // bun compile works with ESM bundles.
  const bundleFile = backend === "pkg" ? "foreman-bundle.cjs" : "foreman-bundle.js";
  const bundlePath = path.join(REPO_ROOT, "dist", bundleFile);
  const targetDir = path.join(outputDir, target);
  const binaryName = getBinaryName(target);
  const binaryPath = path.join(targetDir, binaryName);

  console.log(`\n━━━ Compiling ${target} (${backend}) ━━━`);

  // ── Validate bundle exists ────────────────────────────────────────────────
  if (!existsSync(bundlePath)) {
    const bundleCmd = backend === "pkg" ? "npm run bundle:cjs" : "npm run bundle";
    throw new Error(
      `Bundle not found: ${bundlePath}\n` +
        `Run '${bundleCmd}' first to generate dist/${bundleFile}`
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
    await compilePkg(bundlePath, binaryPath, target, dryRun);
  } else if (backend === "bun") {
    compileBun(bundlePath, binaryPath, target, dryRun);
  } else {
    throw new Error(`Unknown backend: ${String(backend)}`);
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
    sizeBytes,
    durationMs,
  };
}

// ── CLI Argument Parsing ──────────────────────────────────────────────────────

interface CliArgs {
  targets: SupportedTarget[];
  backend: CompilationBackend;
  outputDir: string;
  dryRun: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  const args = argv.slice(2); // Remove node/tsx binary paths

  let targets: SupportedTarget[] = [];
  let backend: CompilationBackend = "pkg";
  let outputDir = path.join(REPO_ROOT, "dist", "binaries");
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

  return { targets, backend, outputDir, dryRun };
}

function printHelp(): void {
  console.log(`
Usage: tsx scripts/compile-binary.ts [options]

Options:
  --all                   Compile all 5 supported targets
  --target <platform-arch>  Single target to compile (repeatable)
  --backend <pkg|bun>     Compilation backend (default: pkg)
  --output-dir <dir>      Output directory (default: dist/binaries)
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

  const { targets, backend, outputDir, dryRun } = cliArgs;

  console.log(`Backend:    ${backend}`);
  console.log(`Output dir: ${outputDir}`);
  console.log(`Targets:    ${targets.join(", ")}`);
  if (dryRun) console.log("🔍 --dry-run: commands will be printed but not executed\n");

  const results: CompileResult[] = [];
  const failures: Array<{ target: SupportedTarget; error: string }> = [];

  for (const target of targets) {
    try {
      const result = await compileTarget({
        target,
        backend,
        outputDir,
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
