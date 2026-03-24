/**
 * Download better-sqlite3 prebuilt .node files for all 5 target platforms.
 *
 * Downloads prebuilt native addons from GitHub Releases and extracts them to:
 *   scripts/prebuilds/{target}/better_sqlite3.node
 *
 * This enables cross-platform binary compilation via compile-binary.ts without
 * requiring native add-on compilation on each target platform.
 *
 * ## Target mapping
 * Foreman target → GitHub release asset platform suffix:
 *   darwin-arm64  → darwin-arm64
 *   darwin-x64    → darwin-x64
 *   linux-x64     → linux-x64
 *   linux-arm64   → linux-arm64
 *   win-x64       → win32-x64  (note: GitHub uses "win32" not "win")
 *
 * ## Node ABI versions (process.versions.modules)
 *   Node 20 → ABI 115
 *   Node 22 → ABI 127
 *   Node 23 → ABI 131
 *   Node 24 → ABI 137
 *   Node 25 → ABI 141
 *
 * ## Usage
 *   tsx scripts/download-prebuilds.ts [options]
 *
 * Options:
 *   --version <ver>     better-sqlite3 version (default: reads from installed package)
 *   --node-abi <num>    Node ABI number (default: 115 for Node 20)
 *   --node <major>      Node.js major version shortcut (e.g. --node 20)
 *   --target <t>        Single target (repeatable, default: all 5)
 *   --output-dir <dir>  Output directory (default: scripts/prebuilds)
 *   --force             Re-download even if prebuilt already exists
 *   --dry-run           Print URLs without downloading
 *   --status            Show status of existing prebuilts and exit
 */

import { execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

// ── Constants ─────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..");

/** GitHub release base URL for better-sqlite3 */
const GITHUB_RELEASE_BASE =
  "https://github.com/WiseLibs/better-sqlite3/releases/download";

/** All 5 supported foreman compilation targets */
export const PREBUILD_TARGETS = [
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "linux-arm64",
  "win-x64",
] as const;

export type PrebuildTarget = (typeof PREBUILD_TARGETS)[number];

/**
 * Map from foreman target names → GitHub asset platform-arch suffix.
 * Note: better-sqlite3 GitHub releases use "win32-x64" not "win-x64".
 */
export const TARGET_TO_ASSET_PLATFORM: Record<PrebuildTarget, string> = {
  "darwin-arm64": "darwin-arm64",
  "darwin-x64": "darwin-x64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
  "win-x64": "win32-x64",
};

/**
 * Node.js ABI (modules) version by Node.js major version.
 * The prebuilt binary must match the ABI of the embedding runtime.
 */
export const NODE_ABI_VERSIONS: Record<number, number> = {
  20: 115,
  22: 127,
  23: 131,
  24: 137,
  25: 141,
};

/** Default Node.js major version for compilation (matches PKG_TARGET_MAP in compile-binary.ts) */
export const DEFAULT_NODE_MAJOR = 20;

/** Path inside the prebuilt tarball where the .node file lives */
const NODE_FILE_IN_TARBALL = "build/Release/better_sqlite3.node";

// ── Utilities ─────────────────────────────────────────────────────────────────

/**
 * Read better-sqlite3 version from the installed node_modules package.json.
 * Falls back to reading from the project's package.json dependencies.
 */
export function getBetterSqlite3Version(repoRoot: string): string {
  // Prefer the installed version (more accurate than declared range)
  const installedPkg = path.join(
    repoRoot,
    "node_modules",
    "better-sqlite3",
    "package.json"
  );
  if (existsSync(installedPkg)) {
    const pkg = JSON.parse(readFileSync(installedPkg, "utf8")) as {
      version: string;
    };
    return pkg.version;
  }

  // Fallback: read from project package.json (may have semver range)
  const projectPkg = JSON.parse(
    readFileSync(path.join(repoRoot, "package.json"), "utf8")
  ) as { dependencies?: Record<string, string> };
  const declared = projectPkg.dependencies?.["better-sqlite3"];
  if (declared) {
    // Strip any semver prefix (^, ~, >=, etc.)
    return declared.replace(/^[^0-9]*/, "");
  }

  throw new Error(
    "Cannot determine better-sqlite3 version: not in node_modules and not in package.json"
  );
}

/**
 * Build the GitHub release asset URL for a given target, version, and Node ABI.
 */
export function buildPrebuiltUrl(
  target: PrebuildTarget,
  version: string,
  nodeAbi: number
): string {
  const assetPlatform = TARGET_TO_ASSET_PLATFORM[target];
  const filename = `better-sqlite3-v${version}-node-v${nodeAbi}-${assetPlatform}.tar.gz`;
  return `${GITHUB_RELEASE_BASE}/v${version}/${filename}`;
}

/**
 * Output path for a prebuilt .node file.
 */
export function getPrebuiltOutputPath(
  outputDir: string,
  target: PrebuildTarget
): string {
  return path.join(outputDir, target, "better_sqlite3.node");
}

// ── Download & Extract ────────────────────────────────────────────────────────

/**
 * Download and extract a better-sqlite3 prebuilt tarball for a single target.
 *
 * Uses curl (macOS/Linux) to download and tar to extract the .node file.
 * This avoids additional npm dependencies — curl and tar are standard on all
 * Unix systems and on Windows (via Git Bash or WSL).
 *
 * @returns Absolute path to the extracted .node file.
 */
export async function downloadPrebuilt(
  target: PrebuildTarget,
  version: string,
  nodeAbi: number,
  outputDir: string,
  options: { force?: boolean; dryRun?: boolean } = {}
): Promise<string> {
  const { force = false, dryRun = false } = options;

  const url = buildPrebuiltUrl(target, version, nodeAbi);
  const outputPath = getPrebuiltOutputPath(outputDir, target);
  const targetDir = path.dirname(outputPath);

  if (!force && existsSync(outputPath)) {
    const sizeKB = (statSync(outputPath).size / 1024).toFixed(1);
    console.log(
      `  ✓ ${target}: already present (${sizeKB} KB) — skipping (use --force to re-download)`
    );
    return outputPath;
  }

  console.log(`  ↓ ${target}: ${url}`);

  if (dryRun) {
    console.log(`    [dry-run] Would extract ${NODE_FILE_IN_TARBALL} → ${outputPath}`);
    return outputPath;
  }

  // Create target directory
  mkdirSync(targetDir, { recursive: true });

  // Download to a temp file, then extract
  const tmpDir = tmpdir();
  const tmpTarball = path.join(tmpDir, `bsq3-prebuild-${target}-${Date.now()}.tar.gz`);

  try {
    // Download with curl (follows GitHub redirects, available on macOS/Linux/Windows)
    execSync(`curl -fsSL -o "${tmpTarball}" "${url}"`, {
      stdio: "pipe",
      timeout: 120_000, // 2 minute timeout
    });

    // Verify download
    const tarSize = statSync(tmpTarball).size;
    if (tarSize === 0) {
      throw new Error(`Downloaded tarball is empty: ${tmpTarball}`);
    }

    // Extract ONLY the .node file from the tarball using tar
    // --strip-components=2 removes the "build/Release/" prefix
    execSync(
      `tar -xzf "${tmpTarball}" -C "${targetDir}" --strip-components=2 "${NODE_FILE_IN_TARBALL}"`,
      { stdio: "pipe", timeout: 30_000 }
    );

    // Verify extraction succeeded
    if (!existsSync(outputPath)) {
      throw new Error(
        `Extraction failed: ${NODE_FILE_IN_TARBALL} not found in tarball.\n` +
          `Expected output: ${outputPath}\n` +
          `Check that better-sqlite3 v${version} has a prebuilt for ${target}.`
      );
    }

    const sizeKB = (statSync(outputPath).size / 1024).toFixed(1);
    console.log(`  ✓ ${target}: better_sqlite3.node extracted (${sizeKB} KB)`);
  } finally {
    // Clean up temp tarball (non-fatal if it fails)
    if (existsSync(tmpTarball)) {
      rmSync(tmpTarball, { force: true });
    }
  }

  return outputPath;
}

// ── Status Check ──────────────────────────────────────────────────────────────

/**
 * Check status of all prebuilts and print a formatted summary table.
 */
export function checkPrebuildsStatus(
  outputDir: string,
  version: string,
  nodeAbi: number
): void {
  console.log(`  better-sqlite3 v${version} — Node ABI v${nodeAbi}`);
  console.log(`  Output dir: ${outputDir}\n`);

  let allPresent = true;

  for (const target of PREBUILD_TARGETS) {
    const nodePath = getPrebuiltOutputPath(outputDir, target);
    if (existsSync(nodePath)) {
      const sizeKB = (statSync(nodePath).size / 1024).toFixed(1);
      console.log(`  ✓ ${target.padEnd(16)}  present  (${sizeKB} KB)`);
    } else {
      console.log(`  ✗ ${target.padEnd(16)}  MISSING`);
      allPresent = false;
    }
  }

  console.log("");
  if (allPresent) {
    console.log("  All 5 prebuilts present — ready for cross-platform compilation.");
  } else {
    console.log("  Run 'tsx scripts/download-prebuilds.ts' to download missing prebuilts.");
  }
}

// ── CLI Argument Parsing ──────────────────────────────────────────────────────

interface CliArgs {
  targets: PrebuildTarget[];
  version: string | null;
  nodeAbi: number;
  outputDir: string;
  force: boolean;
  dryRun: boolean;
  statusOnly: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  const args = argv.slice(2);

  let targets: PrebuildTarget[] = [];
  let version: string | null = null;
  let nodeAbi = NODE_ABI_VERSIONS[DEFAULT_NODE_MAJOR];
  let outputDir = path.join(REPO_ROOT, "scripts", "prebuilds");
  let force = false;
  let dryRun = false;
  let statusOnly = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === "--version" || arg === "-v") {
      version = args[++i] ?? null;
      if (!version) throw new Error("--version requires a value");
    } else if (arg === "--node-abi") {
      const val = args[++i];
      if (!val) throw new Error("--node-abi requires a value");
      nodeAbi = parseInt(val, 10);
      if (isNaN(nodeAbi))
        throw new Error(`--node-abi must be a number, got: ${val}`);
    } else if (arg === "--node") {
      const val = args[++i];
      if (!val) throw new Error("--node requires a value");
      const nodeMajor = parseInt(val, 10);
      const abi = NODE_ABI_VERSIONS[nodeMajor];
      if (!abi) {
        throw new Error(
          `Unknown Node.js major: ${nodeMajor}. Known: ${Object.keys(NODE_ABI_VERSIONS).join(", ")}`
        );
      }
      nodeAbi = abi;
    } else if (arg === "--target" || arg === "-t") {
      const val = args[++i];
      if (!val) throw new Error("--target requires a value");
      if (!(PREBUILD_TARGETS as readonly string[]).includes(val)) {
        throw new Error(
          `Invalid target: "${val}"\nSupported: ${PREBUILD_TARGETS.join(", ")}`
        );
      }
      targets.push(val as PrebuildTarget);
    } else if (arg === "--output-dir" || arg === "-o") {
      outputDir = path.resolve(args[++i] ?? "");
    } else if (arg === "--force" || arg === "-f") {
      force = true;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--status") {
      statusOnly = true;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (targets.length === 0) {
    targets = [...PREBUILD_TARGETS];
  }

  return { targets, version, nodeAbi, outputDir, force, dryRun, statusOnly };
}

function printHelp(): void {
  const abiList = Object.entries(NODE_ABI_VERSIONS)
    .map(([maj, abi]) => `Node ${maj} → ABI ${abi}`)
    .join(", ");

  console.log(`
Usage: tsx scripts/download-prebuilds.ts [options]

Options:
  --version <ver>       better-sqlite3 version (default: installed version)
  --node-abi <num>      Node ABI number (default: ${NODE_ABI_VERSIONS[DEFAULT_NODE_MAJOR]} for Node ${DEFAULT_NODE_MAJOR})
  --node <major>        Node.js major version shortcut (e.g. --node 20)
  --target <t>          Single target to download (repeatable, default: all 5)
  --output-dir <dir>    Output directory (default: scripts/prebuilds)
  --force               Re-download even if file already exists
  --dry-run             Print URLs without downloading
  --status              Show prebuilds status and exit
  --help                Show this help

Supported targets:
  ${PREBUILD_TARGETS.join("\n  ")}

Known Node ABI versions:
  ${abiList}

Examples:
  tsx scripts/download-prebuilds.ts                              # Download all (Node 20)
  tsx scripts/download-prebuilds.ts --node 22                   # Download for Node 22
  tsx scripts/download-prebuilds.ts --target darwin-arm64       # Single target
  tsx scripts/download-prebuilds.ts --force                     # Re-download all
  tsx scripts/download-prebuilds.ts --status                    # Check status

Output:
  scripts/prebuilds/darwin-arm64/better_sqlite3.node
  scripts/prebuilds/darwin-x64/better_sqlite3.node
  scripts/prebuilds/linux-x64/better_sqlite3.node
  scripts/prebuilds/linux-arm64/better_sqlite3.node
  scripts/prebuilds/win-x64/better_sqlite3.node
`);
}

// ── Entry Point ───────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log("═══ better-sqlite3 Prebuilds Downloader ═══\n");

  let cliArgs: CliArgs;
  try {
    cliArgs = parseArgs(process.argv);
  } catch (err) {
    console.error(`Error: ${String(err instanceof Error ? err.message : err)}`);
    process.exit(1);
  }

  const { targets, nodeAbi, outputDir, force, dryRun, statusOnly } = cliArgs;

  // Resolve better-sqlite3 version
  let version: string;
  try {
    version = cliArgs.version ?? getBetterSqlite3Version(REPO_ROOT);
  } catch (err) {
    console.error(`Error: ${String(err instanceof Error ? err.message : err)}`);
    process.exit(1);
  }

  if (statusOnly) {
    checkPrebuildsStatus(outputDir, version, nodeAbi);
    process.exit(0);
  }

  console.log(`better-sqlite3 version: v${version}`);
  console.log(`Node ABI:               v${nodeAbi}`);
  console.log(`Output directory:       ${outputDir}`);
  console.log(`Targets:                ${targets.join(", ")}`);
  if (force) console.log("⚠️  --force: re-downloading existing files");
  if (dryRun) console.log("🔍 --dry-run: URLs printed but not downloaded");
  console.log("");

  const results: Array<{ target: PrebuildTarget; path: string }> = [];
  const failures: Array<{ target: PrebuildTarget; error: string }> = [];

  for (const target of targets) {
    try {
      const outputPath = await downloadPrebuilt(target, version, nodeAbi, outputDir, {
        force,
        dryRun,
      });
      results.push({ target, path: outputPath });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`  ✗ ${target}: ${message}`);
      failures.push({ target, error: message });
    }
  }

  // Summary
  console.log("\n═══ Summary ═══");
  if (results.length > 0) {
    const successCount = dryRun
      ? results.length
      : results.filter((r) => existsSync(r.path)).length;
    console.log(`\n✓ ${successCount} prebuilt(s) ready:`);
    for (const r of results) {
      const rel = path.relative(REPO_ROOT, r.path);
      if (!dryRun && existsSync(r.path)) {
        const sizeKB = (statSync(r.path).size / 1024).toFixed(1);
        console.log(`  ${r.target.padEnd(16)} ${rel}  (${sizeKB} KB)`);
      } else {
        console.log(`  ${r.target.padEnd(16)} ${rel}`);
      }
    }
  }

  if (failures.length > 0) {
    console.log(`\n✗ ${failures.length} failure(s):`);
    for (const f of failures) {
      console.log(`  ${f.target}: ${f.error}`);
    }
    process.exit(1);
  }

  console.log(
    "\nDone. Run 'tsx scripts/compile-binary.ts --all --dry-run' to verify detection."
  );
}

// Only run main() when executed directly
const __currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__currentFile)) {
  main().catch((err: unknown) => {
    console.error("Unexpected error:", err);
    process.exit(1);
  });
}
