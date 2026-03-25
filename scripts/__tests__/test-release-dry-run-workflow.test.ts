/**
 * Tests for the test-release-dry-run workflow.
 *
 * This workflow allows testing the release pipeline on any branch (not just main)
 * without creating a real release. These tests verify the workflow is correctly configured.
 */

import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

describe("test-release-dry-run.yml workflow", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    ".github",
    "workflows",
    "test-release-dry-run.yml"
  );

  it("exists at .github/workflows/test-release-dry-run.yml", () => {
    expect(existsSync(workflowPath)).toBe(true);
  });

  it("triggers ONLY via workflow_dispatch (not automatic on push)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("workflow_dispatch:");
    // Must NOT have push: or pull_request: triggers (would run on every commit)
    expect(contents).not.toMatch(/^on:\s*\n\s+push:/m);
    expect(contents).not.toMatch(/^on:\s*\n\s+pull_request:/m);
  });

  it("has a branch/ref input for testing on non-main branches", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("inputs:");
    expect(contents).toContain("ref:");
  });

  it("validates npm pack contents", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm pack");
    expect(contents).toContain("--dry-run");
    // Should check that dist/ is present
    expect(contents).toContain("dist/");
    // Should check that node_modules/ is excluded
    expect(contents).toContain("node_modules/");
  });

  it("validates version detection (release-please config)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("release-please-config.json");
    expect(contents).toContain(".release-please-manifest.json");
  });

  it("runs binary build matrix for all 3 OS runners", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("ubuntu-latest");
    expect(contents).toContain("macos-latest");
    expect(contents).toContain("windows-latest");
  });

  it("covers all 5 binary targets in matrix", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("linux-x64");
    expect(contents).toContain("linux-arm64");
    expect(contents).toContain("darwin-x64");
    expect(contents).toContain("darwin-arm64");
    expect(contents).toContain("win-x64");
  });

  it("uses --dry-run flag when compiling binaries (no actual pkg execution)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    // The compile step should use --dry-run to avoid actual compilation
    expect(contents).toContain("--dry-run");
    expect(contents).toContain("compile-binary.ts");
  });

  it("does NOT create a GitHub Release (pure dry-run validation)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    // Must NOT upload to GitHub Releases
    expect(contents).not.toContain("softprops/action-gh-release");
    // Must NOT publish to npm
    expect(contents).not.toContain("npm publish");
  });

  it("verifies native addon prebuilds are present", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("prebuilds");
    expect(contents).toContain("prebuilds:status");
  });

  it("has a summary job that depends on all validation jobs", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("needs:");
    // Should have a summary/conclude job
    expect(contents).toContain("Summary");
  });
});
