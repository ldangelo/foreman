/**
 * Bundle script for foreman CLI.
 *
 * Bundles src/cli/index.ts into dist/foreman-bundle.js using esbuild.
 *
 * Configuration:
 * - Target: node20, ESM format
 * - External: better-sqlite3 (native addon, must be loaded at runtime)
 * - Sourcemaps enabled for debugging
 */
import * as esbuild from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

const entryPoint = path.join(repoRoot, "src", "cli", "index.ts");
const outfile = path.join(repoRoot, "dist", "foreman-bundle.js");

async function bundle(): Promise<void> {
  console.log(`Bundling ${entryPoint} → ${outfile}`);

  const result = await esbuild.build({
    entryPoints: [entryPoint],
    outfile,
    bundle: true,
    platform: "node",
    target: "node20",
    format: "esm",
    external: [
      // Native addon: must be loaded at runtime by Node.js, cannot be bundled
      "better-sqlite3",
      // Pi SDK may include native dependencies
      "@mariozechner/pi-coding-agent",
    ],
    // Inject a require() shim so CJS dependencies (e.g., commander v14) can
    // load Node built-ins via require() in an ESM bundle.
    banner: {
      js: `import { createRequire as __createRequire } from "module";
const require = __createRequire(import.meta.url);`,
    },
    sourcemap: true,
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

  console.log("Bundle complete.");
}

bundle().catch((err: unknown) => {
  console.error("Unexpected error during bundle:", err);
  process.exit(1);
});
