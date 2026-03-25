/**
 * Tests for the esbuild bundle script.
 *
 * Verifies:
 * - scripts/bundle.ts exists
 * - package.json has a "bundle" script pointing to tsx scripts/bundle.ts
 * - esbuild is in devDependencies
 * - dist/foreman-bundle.js is a valid ESM entry point after bundling
 * - better-sqlite3 is NOT bundled (remains external)
 */

import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");

describe("bundle script", () => {
  it("scripts/bundle.ts exists", () => {
    const bundleScript = path.join(REPO_ROOT, "scripts", "bundle.ts");
    expect(existsSync(bundleScript)).toBe(true);
  });

  it("package.json has a 'bundle' script", () => {
    const pkg = JSON.parse(
      readFileSync(path.join(REPO_ROOT, "package.json"), "utf-8")
    ) as { scripts?: Record<string, string> };
    expect(pkg.scripts).toBeDefined();
    expect(pkg.scripts!["bundle"]).toBeDefined();
    expect(pkg.scripts!["bundle"]).toContain("bundle");
  });

  it("package.json has esbuild in devDependencies", () => {
    const pkg = JSON.parse(
      readFileSync(path.join(REPO_ROOT, "package.json"), "utf-8")
    ) as { devDependencies?: Record<string, string> };
    expect(pkg.devDependencies).toBeDefined();
    expect(pkg.devDependencies!["esbuild"]).toBeDefined();
  });

  it("bundle script uses tsx to run scripts/bundle.ts", () => {
    const pkg = JSON.parse(
      readFileSync(path.join(REPO_ROOT, "package.json"), "utf-8")
    ) as { scripts?: Record<string, string> };
    const bundleCmd = pkg.scripts!["bundle"];
    expect(bundleCmd).toContain("scripts/bundle.ts");
  });

  it("scripts/bundle.ts targets node20, esm format", () => {
    const content = readFileSync(
      path.join(REPO_ROOT, "scripts", "bundle.ts"),
      "utf-8"
    );
    expect(content).toContain("node20");
    expect(content).toContain('"esm"');
  });

  it("scripts/bundle.ts marks better-sqlite3 as external", () => {
    const content = readFileSync(
      path.join(REPO_ROOT, "scripts", "bundle.ts"),
      "utf-8"
    );
    expect(content).toContain("better-sqlite3");
    expect(content).toContain("external");
  });

  it("dist/foreman-bundle.js exists and runs --help after build", async () => {
    const bundleFile = path.join(REPO_ROOT, "dist", "foreman-bundle.js");
    if (!existsSync(bundleFile)) {
      console.warn(
        "Skipping execution test: dist/foreman-bundle.js not found (run npm run bundle)"
      );
      return;
    }

    const { stdout, stderr } = await execFileAsync(
      process.execPath,
      [bundleFile, "--help"],
      {
        timeout: 15_000,
        env: { ...process.env, NO_COLOR: "1" },
      }
    );

    const output = stdout + stderr;
    expect(output).toContain("Usage: foreman");
    expect(output).toContain("--help");
  });

  it("dist/foreman-bundle.js does not contain bundled better-sqlite3 source", () => {
    const bundleFile = path.join(REPO_ROOT, "dist", "foreman-bundle.js");
    if (!existsSync(bundleFile)) {
      console.warn(
        "Skipping content test: dist/foreman-bundle.js not found (run npm run bundle)"
      );
      return;
    }

    const content = readFileSync(bundleFile, "utf-8");
    // If better-sqlite3 was bundled, we'd see its source code.
    // When external, we only see the import statement.
    const importPattern = /^import .* from ['"]better-sqlite3['"]/m;
    const requirePattern = /require\(['"]better-sqlite3['"]\)/;
    const hasExternalRef =
      importPattern.test(content) || requirePattern.test(content);

    // The bundle should reference better-sqlite3 as an external import/require,
    // not inline its source code. Verify it has some reference to it.
    expect(hasExternalRef).toBe(true);

    // Should NOT contain typical better-sqlite3 C++ module identifiers
    // (those would only appear if it tried to bundle the native code)
    expect(content).not.toContain("sqlite3_prepare_v2");
  });
});
