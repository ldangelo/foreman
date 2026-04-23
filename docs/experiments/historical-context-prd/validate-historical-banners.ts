#!/usr/bin/env node
/**
 * validate-historical-banners.ts
 *
 * Validates that all archival documents in docs/ have the correct historical
 * context banner injected, and that no active operator docs have banners.
 *
 * Usage:
 *   npx tsx docs/experiments/historical-context-prd/validate-historical-banners.ts
 *   npx tsx docs/experiments/historical-context-prd/validate-historical-banners.ts --fix
 *
 * Exit codes:
 *   0  — all validations pass
 *   1  — one or more archival docs missing a banner, or unexpected banners found
 *   2  — manifest or variants file not found or malformed
 */

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ManifestEntry {
  path: string;
  variant: "standard" | "comparison" | "migration" | "beads-rust-only";
  rationale: string;
  lastReviewed?: string;
  status: "archived" | "review" | "active";
}

interface ManifestExclusion {
  path: string;
  reason: "active-operator-doc" | "active-trd" | "generated" | "not-applicable";
  notes?: string;
}

interface Manifest {
  version: string;
  generated: string;
  description?: string;
  documents: ManifestEntry[];
  exclusions: ManifestExclusion[];
  archivalDirectories?: { path: string; notes?: string }[];
}

interface BannerVariant {
  description: string;
  lines: string[];
}

interface BannerVariants {
  variants: Record<string, BannerVariant>;
}

// ---------------------------------------------------------------------------
// Path setup
// ---------------------------------------------------------------------------

const __dirname = dirname(fileURLToPath(import.meta.url));

// DOCS_ROOT is the real docs/ directory in the project
// Script lives at: docs/experiments/historical-context-prd/validate-historical-banners.ts
// So PROJECT_ROOT is: ../../.. from script dir
const PROJECT_ROOT = resolve(__dirname, "..", "..", "..");
const DOCS_ROOT = resolve(PROJECT_ROOT, "docs");

// Experiment dir (where this script lives side-by-side with manifest.json)
const EXPERIMENT_DIR = __dirname;

// Fall back to experiment dir for CI when manifest isn't in docs/.historical-banners/
const FALLBACK_MANIFEST = join(EXPERIMENT_DIR, "manifest.json");
const FALLBACK_VARIANTS = join(EXPERIMENT_DIR, "banner-variants.json");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function loadJson<T>(path: string): T {
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch (err) {
    console.error(`❌  Failed to read or parse JSON: ${path}`);
    console.error((err as Error).message);
    process.exit(2);
  }
}

function existsSync(path: string): boolean {
  try {
    readFileSync(path);
    return true;
  } catch {
    return false;
  }
}

function readDoc(filePath: string): string {
  const full = join(DOCS_ROOT, filePath);
  try {
    return readFileSync(full, "utf-8");
  } catch {
    return ""; // File doesn't exist yet — treat as empty for --fix mode
  }
}

function bannerExists(content: string, lines: string[]): boolean {
  // Must contain all lines, in order, with no interleaved non-banner lines
  const joined = lines.join("\n");
  return content.includes(joined);
}

// ---------------------------------------------------------------------------
// Main validation
// ---------------------------------------------------------------------------

export interface ValidationResult {
  passed: boolean;
  errors: string[];
  warnings: string[];
}

export function validateBanners(
  manifest: Manifest,
  variants: BannerVariants,
  docsRoot: string
): ValidationResult {
  const result: ValidationResult = { passed: true, errors: [], warnings: [] };

  // Build canonical banner strings for exact-match detection
  const allCanonicalBanners = Object.values(variants.variants).map(
    (v) => v.lines.join("\n")
  );

  // --- Phase 1: Check archival documents have banners ---
  for (const entry of manifest.documents) {
    if (entry.status !== "archived") {
      // "review" entries are informational only — skip banner check
      result.warnings.push(
        `⚠️  ${entry.path}: status is '${entry.status}' — banner check skipped`
      );
      continue;
    }

    const variant = variants.variants[entry.variant];
    if (!variant) {
      result.errors.push(
        `❌  ${entry.path}: unknown variant '${entry.variant}'`
      );
      result.passed = false;
      continue;
    }

    const content = readDoc(entry.path);
    if (!content) {
      result.errors.push(
        `❌  ${entry.path}: file not found`
      );
      result.passed = false;
    } else if (!bannerExists(content, variant.lines)) {
      result.errors.push(
        `❌  ${entry.path}: missing '${entry.variant}' banner`
      );
      result.passed = false;
    } else {
      console.log(`✅  ${entry.path}: banner present (${entry.variant})`);
    }
  }

  // --- Phase 2: Check excluded active docs have NO banners ---
  for (const exclusion of manifest.exclusions) {
    const content = readDoc(exclusion.path);
    if (!content) continue; // File not in docs/ yet — skip

    for (const bannerText of allCanonicalBanners) {
      if (content.includes(bannerText)) {
        result.errors.push(
          `❌  ${exclusion.path}: active operator doc has a historical banner — remove it`
        );
        result.passed = false;
      }
    }
    // Only log "no banner" if we didn't already log an error for this file
    if (!result.errors.some((e) => e.includes(exclusion.path))) {
      console.log(`✅  ${exclusion.path}: no banner (excluded as ${exclusion.reason})`);
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// --fix mode: inject missing banners
// ---------------------------------------------------------------------------

export function injectMissingBanners(
  manifest: Manifest,
  variants: BannerVariants,
  docsRoot: string
): { injected: string[]; skipped: string[]; errors: string[] } {
  const injected: string[] = [];
  const skipped: string[] = [];
  const errors: string[] = [];

  for (const entry of manifest.documents) {
    if (entry.status !== "archived") {
      skipped.push(`${entry.path} (status: ${entry.status})`);
      continue;
    }

    const variant = variants.variants[entry.variant];
    if (!variant) {
      errors.push(`${entry.path}: unknown variant '${entry.variant}'`);
      continue;
    }

    const full = join(docsRoot, entry.path);
    let content: string;
    try {
      content = readFileSync(full, "utf-8");
    } catch {
      errors.push(`${entry.path}: file not found`);
      continue;
    }

    if (bannerExists(content, variant.lines)) {
      skipped.push(`${entry.path} (already has banner)`);
      continue;
    }

    const banner = variant.lines.join("\n") + "\n\n";
    const newContent = banner + content;
    writeFileSync(full, newContent, "utf-8");
    injected.push(`${entry.path} (${entry.variant})`);
    console.log(`✅  ${entry.path}: banner injected (${entry.variant})`);
  }

  return { injected, skipped, errors };
}

// ---------------------------------------------------------------------------
// CLI entrypoint
// ---------------------------------------------------------------------------

function main() {
  const args = process.argv.slice(2);
  const fixMode = args.includes("--fix");

  // Prefer docs/.historical-banners/ (production location), fall back to experiment dir
  const prodManifest = join(DOCS_ROOT, ".historical-banners", "manifest.json");
  const prodVariants = join(DOCS_ROOT, ".historical-banners", "banner-variants.json");

  const manifestPath = existsSync(prodManifest) ? prodManifest : FALLBACK_MANIFEST;
  const variantsPath = existsSync(prodVariants) ? prodVariants : FALLBACK_VARIANTS;

  const manifest: Manifest = loadJson(manifestPath);
  const variants: BannerVariants = loadJson(variantsPath);

  console.log(`📋  Manifest: ${manifestPath}`);
  console.log(`📋  Variants:  ${variantsPath}`);
  console.log("");

  if (fixMode) {
    const { injected, skipped, errors } = injectMissingBanners(
      manifest,
      variants,
      DOCS_ROOT
    );
    console.log("\n--- Summary ---");
    if (injected.length) console.log(`Injected: ${injected.length}`);
    if (skipped.length) console.log(`Skipped:  ${skipped.length}`);
    if (errors.length) {
      console.log(`Errors:   ${errors.length}`);
      for (const e of errors) console.log(`  ${e}`);
    }
    process.exit(errors.length > 0 ? 1 : 0);
  }

  const result = validateBanners(manifest, variants, DOCS_ROOT);

  if (result.warnings.length) {
    console.log("--- Warnings ---");
    for (const w of result.warnings) console.log(`  ${w}`);
    console.log("");
  }

  if (result.passed) {
    console.log("✅  All historical banner validations passed.");
    process.exit(0);
  } else {
    console.log("❌  Validation failed:");
    for (const err of result.errors) {
      console.log(`  ${err}`);
    }
    process.exit(1);
  }
}

// Only run if executed directly (not imported for testing)
if (process.argv[1]?.includes("validate-historical-banners")) {
  main();
}
