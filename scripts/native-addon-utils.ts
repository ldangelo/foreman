/**
 * Utilities for locating and copying better-sqlite3 native addon.
 *
 * better-sqlite3 ships a platform-specific .node binary (a native Node.js
 * addon compiled with node-gyp). When we bundle the foreman CLI with esbuild,
 * we mark better-sqlite3 as external so its JS files still load at runtime via
 * require(). However, the JS loader ultimately calls require('bindings') which
 * resolves the .node binary relative to the package's own directory structure.
 *
 * In a bundled/standalone context the node_modules tree may not be present, so
 * we copy the .node binary alongside the bundle in dist/ and use the
 * nativeBinding option of the Database constructor to point directly at it.
 */

import { existsSync, mkdirSync, copyFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ── Types ────────────────────────────────────────────────────────────────────

export interface PlatformInfo {
  /** Normalised platform string, e.g. "darwin", "linux", "win" */
  platform: string;
  /** Architecture string, e.g. "arm64", "x64" */
  arch: string;
  /** Combined key used for display/logging, e.g. "darwin-arm64" */
  key: string;
}

// ── Platform Detection ───────────────────────────────────────────────────────

/**
 * Detect the current platform and architecture, normalising win32 → win so the
 * strings match prebuild-install / node-pre-gyp naming conventions.
 */
export function detectPlatform(): PlatformInfo {
  const rawPlatform = process.platform;
  const rawArch = process.arch;

  // Normalise platform: prebuild-install uses "win" not "win32"
  const platform = rawPlatform === "win32" ? "win" : rawPlatform;

  // Preserve arch as-is (arm64, x64, ia32, arm, …)
  const arch = rawArch;

  return { platform, arch, key: `${platform}-${arch}` };
}

// ── Path Resolution ──────────────────────────────────────────────────────────

/**
 * Return the absolute path to the better-sqlite3 native addon as installed
 * under node_modules by `npm install` / `prebuild-install`.
 *
 * @param repoRoot - Absolute path to the repository root (where node_modules lives).
 * @returns Absolute path to better_sqlite3.node, or null if not found.
 */
export function getBetterSqlite3NodePath(repoRoot: string): string | null {
  // Primary location: built/fetched by prebuild-install during npm install
  const primary = path.join(
    repoRoot,
    "node_modules",
    "better-sqlite3",
    "build",
    "Release",
    "better_sqlite3.node"
  );

  if (existsSync(primary)) {
    return primary;
  }

  // Fallback: prebuilds directory (some better-sqlite3 versions use this layout)
  const { key } = detectPlatform();
  const fallback = path.join(
    repoRoot,
    "node_modules",
    "better-sqlite3",
    "prebuilds",
    key,
    "node.napi.node"
  );

  if (existsSync(fallback)) {
    return fallback;
  }

  return null;
}

// ── Copy Step ────────────────────────────────────────────────────────────────

/**
 * Copy the better-sqlite3 native addon into the bundle output directory.
 *
 * After this step, `<outputDir>/better_sqlite3.node` will exist alongside the
 * bundle. The ForemanStore constructor detects this file and passes its path as
 * the `nativeBinding` option to avoid relying on node_modules at runtime.
 *
 * @param repoRoot  - Absolute path to the repository root.
 * @param outputDir - Directory where the bundle was written (e.g. dist/).
 * @throws Error if the .node binary cannot be located.
 */
export function copyNativeAddon(repoRoot: string, outputDir: string): void {
  const { key } = detectPlatform();
  const sourcePath = getBetterSqlite3NodePath(repoRoot);

  if (!sourcePath) {
    throw new Error(
      `[postbundle] Could not find better_sqlite3.node for ${key} in node_modules. ` +
        "Run `npm install` to fetch the prebuilt binary."
    );
  }

  mkdirSync(outputDir, { recursive: true });

  const destPath = path.join(outputDir, "better_sqlite3.node");
  copyFileSync(sourcePath, destPath);

  const sizeKB = (statSync(destPath).size / 1024).toFixed(1);
  console.log(
    `[postbundle] Copied better_sqlite3.node (${key}) → ${destPath} (${sizeKB} KB)`
  );
}

// ── Standalone Entry Point ───────────────────────────────────────────────────

/**
 * When this module is executed directly (`tsx scripts/native-addon-utils.ts`)
 * run the copy step using defaults derived from the script's own location.
 */
const __currentFile = fileURLToPath(import.meta.url);

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__currentFile)) {
  const __dirname = path.dirname(__currentFile);
  const repoRoot = path.resolve(__dirname, "..");
  const outputDir = path.join(repoRoot, "dist");

  try {
    copyNativeAddon(repoRoot, outputDir);
  } catch (err: unknown) {
    console.error(String(err));
    process.exit(1);
  }
}
