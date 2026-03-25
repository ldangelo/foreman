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

describe("homebrew auto-update workflow", () => {
  const root = path.resolve(__dirname, "../../../");

  it(".github/workflows/update-homebrew-tap.yml exists", () => {
    expect(
      existsSync(
        path.join(root, ".github/workflows/update-homebrew-tap.yml")
      )
    ).toBe(true);
  });

  it(".github/workflows/release-binaries.yml exists", () => {
    expect(
      existsSync(
        path.join(root, ".github/workflows/release-binaries.yml")
      )
    ).toBe(true);
  });

  it("update-homebrew-tap.yml triggers on release-binaries completion", () => {
    const raw = readFileSync(
      path.join(root, ".github/workflows/update-homebrew-tap.yml"),
      "utf8"
    );
    // Must reference the Release Binaries workflow
    expect(raw).toContain("Release Binaries");
    // Must only run on success
    expect(raw).toContain("success");
  });

  it("update-homebrew-tap.yml has manual workflow_dispatch trigger", () => {
    const raw = readFileSync(
      path.join(root, ".github/workflows/update-homebrew-tap.yml"),
      "utf8"
    );
    expect(raw).toContain("workflow_dispatch");
  });

  it("update-homebrew-tap.yml handles all 4 unix platforms", () => {
    const raw = readFileSync(
      path.join(root, ".github/workflows/update-homebrew-tap.yml"),
      "utf8"
    );
    expect(raw).toContain("darwin-arm64");
    expect(raw).toContain("darwin-x64");
    expect(raw).toContain("linux-x64");
    expect(raw).toContain("linux-arm64");
  });

  it("homebrew-tap/Formula/foreman.rb exists", () => {
    expect(
      existsSync(path.join(root, "homebrew-tap/Formula/foreman.rb"))
    ).toBe(true);
  });

  it("foreman.rb has version field", () => {
    const raw = readFileSync(
      path.join(root, "homebrew-tap/Formula/foreman.rb"),
      "utf8"
    );
    expect(raw).toMatch(/version "\d+\.\d+\.\d+"/);
  });

  it("foreman.rb has placeholder sha256 values for all platforms", () => {
    const raw = readFileSync(
      path.join(root, "homebrew-tap/Formula/foreman.rb"),
      "utf8"
    );
    // Should have sha256 entries for 4 platforms
    const sha256Matches = raw.match(/sha256 "[^"]+"/g) ?? [];
    expect(sha256Matches.length).toBe(4);
  });

  it("foreman.rb uses on_macos/on_linux DSL for platform detection", () => {
    const raw = readFileSync(
      path.join(root, "homebrew-tap/Formula/foreman.rb"),
      "utf8"
    );
    expect(raw).toContain("on_macos");
    expect(raw).toContain("on_linux");
    expect(raw).toContain("on_arm");
    expect(raw).toContain("on_intel");
  });

  it("foreman.rb has smoke test block", () => {
    const raw = readFileSync(
      path.join(root, "homebrew-tap/Formula/foreman.rb"),
      "utf8"
    );
    expect(raw).toContain("test do");
    expect(raw).toContain("foreman --version");
  });

  it("foreman.rb install uses libexec for binary co-location", () => {
    const raw = readFileSync(
      path.join(root, "homebrew-tap/Formula/foreman.rb"),
      "utf8"
    );
    // Binary and side-car must be co-located in libexec
    expect(raw).toContain("libexec");
    expect(raw).toContain("better_sqlite3.node");
  });

  it("update-homebrew-tap.yml uses SSH deploy key (not PAT)", () => {
    const raw = readFileSync(
      path.join(root, ".github/workflows/update-homebrew-tap.yml"),
      "utf8"
    );
    // Should use TAP_DEPLOY_KEY SSH secret
    expect(raw).toContain("TAP_DEPLOY_KEY");
    // Should use ssh-key parameter for checkout
    expect(raw).toContain("ssh-key");
  });

  it("update-homebrew-tap.yml pushes to the correct tap repo", () => {
    const raw = readFileSync(
      path.join(root, ".github/workflows/update-homebrew-tap.yml"),
      "utf8"
    );
    expect(raw).toContain("oftheangels/homebrew-tap");
  });
});
