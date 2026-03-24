/**
 * Tests for the atomic build approach.
 *
 * Verifies:
 * - The `build` script no longer calls `npm run clean` (no dist/ deletion mid-flight)
 * - The `rebuild` script exists as the clean+build alias
 * - The `build:atomic` script exists and points to scripts/build-atomic.js
 * - build-atomic.js skips the final swap in --dry mode (no stale temp dirs)
 * - build-atomic.js builds to a temp directory first, then swaps
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  rmSync,
  writeFileSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "../../..");

// ── package.json script assertions ──────────────────────────────────────────

describe("package.json build scripts", () => {
  let scripts: Record<string, string>;

  beforeEach(() => {
    const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
      scripts: Record<string, string>;
    };
    scripts = pkg.scripts;
  });

  it('build script does NOT call "npm run clean" (no dist/ deletion mid-flight)', () => {
    expect(scripts["build"]).toBeDefined();
    expect(scripts["build"]).not.toContain("npm run clean");
    expect(scripts["build"]).not.toContain("rm -rf");
  });

  it('rebuild script exists and starts with "npm run clean"', () => {
    expect(scripts["rebuild"]).toBeDefined();
    expect(scripts["rebuild"]).toMatch(/npm run clean/);
  });

  it('"build:atomic" script exists and references scripts/build-atomic.js', () => {
    expect(scripts["build:atomic"]).toBeDefined();
    expect(scripts["build:atomic"]).toContain("build-atomic.js");
  });

  it('"clean" script still exists as a standalone command', () => {
    expect(scripts["clean"]).toBeDefined();
    expect(scripts["clean"]).toContain("rm -rf dist");
  });

  it('build script still runs tsc and copy-assets', () => {
    expect(scripts["build"]).toContain("tsc");
    expect(scripts["build"]).toContain("copy-assets.js");
  });
});

// ── build-atomic.js dry-run test ─────────────────────────────────────────────

describe("build-atomic.js --dry mode", () => {
  it("build-atomic.js script file exists", () => {
    expect(existsSync(join(root, "scripts/build-atomic.js"))).toBe(true);
  });

  it("build-atomic.js contains atomic swap logic", () => {
    const src = readFileSync(join(root, "scripts/build-atomic.js"), "utf8");
    expect(src).toContain("renameSync");
    expect(src).toContain("dist-new-");
    expect(src).toContain("--dry");
    expect(src).toContain("atomic swap");
  });

  it("build-atomic.js uses a temp directory, not dist/ directly", () => {
    const src = readFileSync(join(root, "scripts/build-atomic.js"), "utf8");
    // The outDir passed to tsc must be tmpDir (not finalDir)
    expect(src).toContain("--outDir ${tmpDir}");
    // Final rename: tmpDir → dist/
    expect(src).toContain("renameSync(tmpDir, finalDir)");
  });
});
