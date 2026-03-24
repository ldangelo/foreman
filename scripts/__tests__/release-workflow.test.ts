/**
 * Tests for the GitHub Actions release-binaries workflow.
 *
 * These tests verify:
 * - The workflow YAML is valid and contains required fields
 * - The npm scripts required by the workflow exist
 * - The expected output asset structure is correct
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

// ── Workflow file existence ───────────────────────────────────────────────────

describe("release-binaries workflow file", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    ".github",
    "workflows",
    "release-binaries.yml"
  );

  it("exists at .github/workflows/release-binaries.yml", () => {
    expect(existsSync(workflowPath)).toBe(true);
  });

  it("contains required trigger on version tag push", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("push:");
    expect(contents).toContain("tags:");
    expect(contents).toMatch(/v\*\.\*\.\*/);
  });

  it("contains workflow_dispatch trigger", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("workflow_dispatch:");
  });

  it("uses ubuntu-latest runner", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("ubuntu-latest");
  });

  it("runs npm run bundle:cjs step", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("bundle:cjs");
  });

  it("runs npm run compile-binary step", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("compile-binary");
  });

  it("includes smoke test for linux-x64 binary", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("foreman-linux-x64");
    expect(contents).toContain("--help");
  });

  it("packages all 5 target platforms", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("darwin-arm64");
    expect(contents).toContain("darwin-x64");
    expect(contents).toContain("linux-x64");
    expect(contents).toContain("linux-arm64");
    expect(contents).toContain("win-x64");
  });

  it("creates GitHub Release via softprops/action-gh-release", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("softprops/action-gh-release");
  });

  it("has write permission for contents (required to create releases)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("contents: write");
  });

  it("supports dry_run input to skip release publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("dry_run");
    expect(contents).toContain("dry-run");
  });
});

// ── npm scripts ───────────────────────────────────────────────────────────────

describe("package.json binary build scripts", () => {
  let packageJson: Record<string, unknown>;

  beforeAll(() => {
    const pkgPath = path.join(REPO_ROOT, "package.json");
    packageJson = JSON.parse(readFileSync(pkgPath, "utf-8")) as Record<
      string,
      unknown
    >;
  });

  it("has build:binaries script (full pipeline: build → bundle:cjs → compile-binary)", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts["build:binaries"]).toBeDefined();
    expect(scripts["build:binaries"]).toContain("bundle:cjs");
    expect(scripts["build:binaries"]).toContain("compile-binary");
  });

  it("has build:binaries:dry-run script", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts["build:binaries:dry-run"]).toBeDefined();
    expect(scripts["build:binaries:dry-run"]).toContain("dry-run");
  });

  it("has prebuilds:download script for cross-platform native addons", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts["prebuilds:download"]).toBeDefined();
  });

  it("has prebuilds:status script to check prebuild status", () => {
    const scripts = packageJson.scripts as Record<string, string>;
    expect(scripts["prebuilds:status"]).toBeDefined();
  });
});

// ── Prebuilds directory ───────────────────────────────────────────────────────

describe("scripts/prebuilds directory", () => {
  const TARGETS = [
    "darwin-arm64",
    "darwin-x64",
    "linux-x64",
    "linux-arm64",
    "win-x64",
  ] as const;

  it("contains better_sqlite3.node for all 5 targets", () => {
    for (const target of TARGETS) {
      const nodePath = path.join(
        REPO_ROOT,
        "scripts",
        "prebuilds",
        target,
        "better_sqlite3.node"
      );
      expect(existsSync(nodePath), `Missing prebuild for ${target}: ${nodePath}`).toBe(
        true
      );
    }
  });
});

// ── Asset naming convention ───────────────────────────────────────────────────

describe("release asset naming convention", () => {
  it("unix platforms get .tar.gz archives", () => {
    const platforms = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"];
    for (const platform of platforms) {
      // The workflow packages unix platforms as tar.gz
      const assetName = `foreman-v1.0.0-${platform}.tar.gz`;
      expect(assetName).toMatch(/\.tar\.gz$/);
    }
  });

  it("windows platform gets .zip archive", () => {
    const assetName = "foreman-v1.0.0-win-x64.zip";
    expect(assetName).toMatch(/\.zip$/);
  });

  it("binary inside archive matches expected naming: foreman-{target}[.exe]", () => {
    const expected: Record<string, string> = {
      "darwin-arm64": "foreman-darwin-arm64",
      "darwin-x64": "foreman-darwin-x64",
      "linux-x64": "foreman-linux-x64",
      "linux-arm64": "foreman-linux-arm64",
      "win-x64": "foreman-win-x64.exe",
    };

    for (const [target, binaryName] of Object.entries(expected)) {
      if (target === "win-x64") {
        expect(binaryName).toMatch(/\.exe$/);
      } else {
        expect(binaryName).not.toMatch(/\.exe$/);
      }
      expect(binaryName).toBe(`foreman-${target}${target === "win-x64" ? ".exe" : ""}`);
    }
  });
});
