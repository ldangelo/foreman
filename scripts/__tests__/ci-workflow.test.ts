/**
 * Tests for the GitHub Actions CI workflow and linting configuration.
 *
 * These tests verify:
 * - ci.yml has a lint step before type check and tests
 * - ESLint configuration file exists and is valid JS
 * - Lint script is present in package.json
 * - ESLint dependencies are in devDependencies
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

// ── CI workflow ───────────────────────────────────────────────────────────────

describe("CI workflow (ci.yml)", () => {
  const workflowPath = path.join(REPO_ROOT, ".github", "workflows", "ci.yml");
  let contents: string;

  beforeAll(() => {
    contents = readFileSync(workflowPath, "utf-8");
  });

  it("exists at .github/workflows/ci.yml", () => {
    expect(existsSync(workflowPath)).toBe(true);
  });

  it("has a lint step", () => {
    expect(contents).toContain("Lint");
    expect(contents).toContain("npm run lint");
  });

  it("lint step comes before type check", () => {
    const lintIdx = contents.indexOf("npm run lint");
    const typecheckIdx = contents.indexOf("tsc --noEmit");
    expect(lintIdx).toBeGreaterThan(-1);
    expect(typecheckIdx).toBeGreaterThan(-1);
    expect(lintIdx).toBeLessThan(typecheckIdx);
  });

  it("lint step comes before test step", () => {
    const lintIdx = contents.indexOf("npm run lint");
    const testIdx = contents.indexOf("npm test");
    expect(lintIdx).toBeGreaterThan(-1);
    expect(testIdx).toBeGreaterThan(-1);
    expect(lintIdx).toBeLessThan(testIdx);
  });

  it("triggers on PR to main and dev branches", () => {
    expect(contents).toContain("pull_request:");
    expect(contents).toContain("main");
    expect(contents).toContain("dev");
  });
});

// ── ESLint configuration ──────────────────────────────────────────────────────

describe("ESLint configuration", () => {
  const configPath = path.join(REPO_ROOT, "eslint.config.js");
  let contents: string;

  beforeAll(() => {
    contents = readFileSync(configPath, "utf-8");
  });

  it("eslint.config.js exists at repo root", () => {
    expect(existsSync(configPath)).toBe(true);
  });

  it("uses flat config format (ESLint v9+)", () => {
    // Flat config: uses default export, not module.exports
    expect(contents).toContain("export default");
  });

  it("uses typescript-eslint", () => {
    expect(contents).toContain("typescript-eslint");
  });

  it("extends recommended rules", () => {
    expect(contents).toContain("recommended");
  });

  it("ignores dist/ directory", () => {
    expect(contents).toContain("dist/");
    expect(contents).toContain("ignores");
  });

  it("ignores node_modules/ directory", () => {
    expect(contents).toContain("node_modules/");
  });

  it("has relaxed rules for test files", () => {
    expect(contents).toContain("__tests__");
    expect(contents).toContain("*.test.ts");
  });

  it("has relaxed rules for scripts/", () => {
    expect(contents).toContain("scripts/**");
  });
});

// ── package.json lint scripts ─────────────────────────────────────────────────

describe("package.json lint configuration", () => {
  let packageJson: Record<string, unknown>;

  beforeAll(() => {
    const pkgPath = path.join(REPO_ROOT, "package.json");
    packageJson = JSON.parse(readFileSync(pkgPath, "utf-8")) as Record<string, unknown>;
  });

  it("has lint script", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts.lint).toBeDefined();
    expect(scripts.lint).toContain("eslint");
  });

  it("lint script targets src/ and scripts/", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts.lint).toContain("src/");
  });

  it("has lint:fix script", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts["lint:fix"]).toBeDefined();
    expect(scripts["lint:fix"]).toContain("--fix");
  });

  it("has eslint in devDependencies", () => {
    const devDeps = packageJson.devDependencies as Record<string, string>;
    expect(devDeps.eslint).toBeDefined();
    expect(devDeps.eslint).toMatch(/^\^?\d+\./);
  });

  it("has @eslint/js in devDependencies", () => {
    const devDeps = packageJson.devDependencies as Record<string, string>;
    expect(devDeps["@eslint/js"]).toBeDefined();
  });

  it("has typescript-eslint in devDependencies", () => {
    const devDeps = packageJson.devDependencies as Record<string, string>;
    expect(devDeps["typescript-eslint"]).toBeDefined();
  });
});
