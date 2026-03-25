/**
 * CJS Bundle script for foreman CLI binary compilation.
 *
 * Bundles src/cli/index.ts into dist/foreman-bundle.cjs using esbuild in
 * CommonJS format. This bundle is specifically for standalone binary
 * compilation with pkg, which requires CJS-compatible entry points.
 *
 * Key differences from bundle.ts (ESM):
 * - format: "cjs" instead of "esm"
 * - No ESM banner (require() is available natively in CJS)
 * - esbuild auto-polyfills import.meta.url → __filename-based equivalent
 * - Output: dist/foreman-bundle.cjs
 *
 * Usage:
 *   tsx scripts/bundle-cjs.ts
 *   npm run bundle:cjs
 */
import * as esbuild from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { readFileSync, writeFileSync } from "node:fs";
import { copyNativeAddon } from "./native-addon-utils.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

const entryPoint = path.join(repoRoot, "src", "cli", "index.ts");
const outfile = path.join(repoRoot, "dist", "foreman-bundle.cjs");

async function bundleCjs(): Promise<void> {
  console.log(`Bundling (CJS) ${entryPoint} → ${outfile}`);

  const result = await esbuild.build({
    entryPoints: [entryPoint],
    outfile,
    bundle: true,
    platform: "node",
    target: "node20",
    format: "cjs",
    external: [
      // Native addon: must be loaded at runtime by Node.js, cannot be bundled
      "better-sqlite3",
      // @mariozechner/pi-coding-agent is bundled (no native .node files) into the
      // CJS output. esbuild handles ESM → CJS conversion for this package.
      // (Unlike the ESM bundle where it was external to avoid startup order issues.)
    ],
    // No ESM banner needed — CJS has require() natively.
    // Add a banner to define importMetaUrl as a CJS-compatible replacement for
    // import.meta.url (which esbuild can't auto-polyfill in CJS format).
    // The `define` option replaces all `import.meta.url` references with
    // `importMetaUrl` which resolves correctly via __filename in CJS context.
    banner: {
      js: `const importMetaUrl = require("url").pathToFileURL(__filename).href;`,
    },
    define: {
      "import.meta.url": "importMetaUrl",
    },
    sourcemap: false, // Skip sourcemaps for binary bundles (reduces size)
    minify: false, // Keep readable for debugging
    metafile: true,
    logLevel: "info",
  });

  if (result.errors.length > 0) {
    console.error("Bundle failed with errors:");
    for (const err of result.errors) {
      console.error(` - ${err.text}`);
    }
    process.exit(1);
  }

  if (result.warnings.length > 0) {
    for (const warn of result.warnings) {
      console.warn(`Warning: ${warn.text}`);
    }
  }

  // Print bundle size info
  if (result.metafile) {
    const outputs = result.metafile.outputs;
    for (const [file, info] of Object.entries(outputs)) {
      const sizeKB = (info.bytes / 1024).toFixed(1);
      console.log(`  ${path.basename(file)}: ${sizeKB} KB`);
    }
  }

  // ── Post-process: patch pi-coding-agent startup ────────────────────────────
  // The pi-coding-agent reads its package.json at module initialization time.
  // When running as a standalone pkg binary, this file may not be in the
  // snapshot, causing a fatal ENOENT error. We wrap the readFileSync call in
  // a try/catch so the binary gracefully falls back to defaults.
  //
  // Pattern to find: var pkg = JSON.parse(...readFileSync(getPackageJsonPath()...
  // Replace with: a try/catch wrapped version that provides pi defaults on failure.
  let bundleContents = readFileSync(outfile, "utf-8");
  const PATTERN = /var pkg = JSON\.parse\(\(0, import_fs\.readFileSync\)\(getPackageJsonPath\(\), "utf-8"\)\);/;
  const REPLACEMENT = `var pkg = (() => { try { return JSON.parse((0, import_fs.readFileSync)(getPackageJsonPath(), "utf-8")); } catch { return { name: "foreman", version: "0.0.0", piConfig: { name: "pi", configDir: ".pi" } }; } })();`;

  if (PATTERN.test(bundleContents)) {
    bundleContents = bundleContents.replace(PATTERN, REPLACEMENT);
    writeFileSync(outfile, bundleContents);
    console.log("  ✓ Patched pi-coding-agent package.json startup (added try/catch fallback)");
  } else {
    console.warn("  ⚠️  Could not find pi-coding-agent package.json read pattern — binary may fail if package.json is missing from snapshot");
  }

  console.log("CJS bundle complete.");

  // ── Postbundle: copy native addon ──────────────────────────────────────────
  // Copies better_sqlite3.node into dist/ so the bundled CLI can load the
  // native addon without requiring a full node_modules tree.
  const outDir = path.dirname(outfile);
  copyNativeAddon(repoRoot, outDir);
}

bundleCjs().catch((err: unknown) => {
  console.error("Unexpected error during CJS bundle:", err);
  process.exit(1);
});
