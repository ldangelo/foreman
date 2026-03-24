/**
 * Tests for dynamic version resolution in the CLI.
 *
 * The CLI must report the version from package.json (not a hardcoded string)
 * so that release-please version bumps are automatically reflected in
 * `foreman --version` output.
 */

import { describe, it, expect } from "vitest";
import { execFileSync, execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";

const execFileAsync = promisify(execFile);

function findTsx(): string {
  const candidates = [
    path.resolve(__dirname, "../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../node_modules/.bin/tsx"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return candidates[0];
}

const TSX = findTsx();
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

/** Read the actual version string from package.json */
function packageVersion(): string {
  const pkgPath = path.resolve(__dirname, "../../../package.json");
  const raw = readFileSync(pkgPath, "utf8");
  return (JSON.parse(raw) as { version: string }).version;
}

describe("foreman --version (dynamic version resolution)", () => {
  it("reports a non-empty version string", async () => {
    const { stdout } = await execFileAsync(TSX, [CLI, "--version"], {
      timeout: 15_000,
    });
    expect(stdout.trim()).not.toBe("");
  });

  it("version matches package.json at runtime", async () => {
    const expected = packageVersion();
    const { stdout } = await execFileAsync(TSX, [CLI, "--version"], {
      timeout: 15_000,
    });
    expect(stdout.trim()).toBe(expected);
  });

  it("version follows semver format (X.Y.Z or X.Y.Z-pre)", async () => {
    const { stdout } = await execFileAsync(TSX, [CLI, "--version"], {
      timeout: 15_000,
    });
    const semverRe = /^\d+\.\d+\.\d+(-[\w.]+)?$/;
    expect(stdout.trim()).toMatch(semverRe);
  });
});

describe("package.json version field", () => {
  it("has a version field", () => {
    const version = packageVersion();
    expect(typeof version).toBe("string");
    expect(version.length).toBeGreaterThan(0);
  });

  it("version follows semver format", () => {
    const version = packageVersion();
    const semverRe = /^\d+\.\d+\.\d+(-[\w.]+)?$/;
    expect(version).toMatch(semverRe);
  });
});

describe("release-please config files", () => {
  const root = path.resolve(__dirname, "../../../");

  it("release-please-config.json exists", () => {
    expect(existsSync(path.join(root, "release-please-config.json"))).toBe(
      true
    );
  });

  it("release-please-config.json is valid JSON", () => {
    const raw = readFileSync(
      path.join(root, "release-please-config.json"),
      "utf8"
    );
    expect(() => JSON.parse(raw)).not.toThrow();
  });

  it(".release-please-manifest.json exists", () => {
    expect(
      existsSync(path.join(root, ".release-please-manifest.json"))
    ).toBe(true);
  });

  it(".release-please-manifest.json contains root package version", () => {
    const raw = readFileSync(
      path.join(root, ".release-please-manifest.json"),
      "utf8"
    );
    const manifest = JSON.parse(raw) as Record<string, string>;
    expect(manifest["."]).toBeDefined();
    const semverRe = /^\d+\.\d+\.\d+(-[\w.]+)?$/;
    expect(manifest["."]).toMatch(semverRe);
  });

  it(".release-please-manifest.json version matches package.json", () => {
    const raw = readFileSync(
      path.join(root, ".release-please-manifest.json"),
      "utf8"
    );
    const manifest = JSON.parse(raw) as Record<string, string>;
    expect(manifest["."]).toBe(packageVersion());
  });

  it("CHANGELOG.md exists", () => {
    expect(existsSync(path.join(root, "CHANGELOG.md"))).toBe(true);
  });

  it(".github/workflows/release.yml exists", () => {
    expect(
      existsSync(path.join(root, ".github/workflows/release.yml"))
    ).toBe(true);
  });
});
