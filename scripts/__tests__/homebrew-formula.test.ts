/**
 * Tests for the Homebrew formula (homebrew-tap/Formula/foreman.rb).
 *
 * These tests verify:
 * - The formula file exists at the expected location
 * - Platform-specific URLs cover all 4 Unix targets (darwin-arm64, darwin-x64, linux-x64, linux-arm64)
 * - SHA256 placeholders are present (to be auto-updated by CI)
 * - The formula installs the binary to bin/
 * - Caveats mention required dependencies (br, ANTHROPIC_API_KEY)
 * - Test block is present for brew test
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const FORMULA_PATH = path.join(REPO_ROOT, "homebrew-tap", "Formula", "foreman.rb");

// ── File existence ────────────────────────────────────────────────────────────

describe("homebrew-tap/Formula/foreman.rb", () => {
  it("exists at homebrew-tap/Formula/foreman.rb", () => {
    expect(existsSync(FORMULA_PATH)).toBe(true);
  });

  it("is readable", () => {
    expect(() => readFileSync(FORMULA_PATH, "utf-8")).not.toThrow();
  });
});

// ── Formula content ───────────────────────────────────────────────────────────

describe("Homebrew formula content", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(FORMULA_PATH, "utf-8");
  });

  it("defines class Foreman < Formula", () => {
    expect(content).toContain("class Foreman < Formula");
  });

  it("has a description", () => {
    expect(content).toContain("desc ");
    expect(content).toContain("foreman");
  });

  it("has homepage pointing to ldangelo/foreman", () => {
    expect(content).toContain("homepage");
    expect(content).toContain("ldangelo/foreman");
  });

  it("has a version field", () => {
    expect(content).toContain("version ");
    expect(content).toMatch(/version "\d+\.\d+\.\d+"/);
  });

  it("has MIT license", () => {
    expect(content).toContain('license "MIT"');
  });

  it("covers darwin arm64 (Apple Silicon)", () => {
    expect(content).toContain("darwin");
    expect(content).toContain("arm");
    expect(content).toContain("darwin-arm64");
  });

  it("covers darwin intel (x64)", () => {
    expect(content).toContain("intel");
    expect(content).toContain("darwin-x64");
  });

  it("covers linux x64", () => {
    expect(content).toContain("linux");
    expect(content).toContain("linux-x64");
  });

  it("covers linux arm64", () => {
    expect(content).toContain("linux-arm64");
  });

  it("uses on_macos/on_linux conditional blocks", () => {
    expect(content).toContain("on_macos");
    expect(content).toContain("on_linux");
  });

  it("has url fields for all platforms", () => {
    const urlMatches = content.match(/^\s+url "/gm);
    expect(urlMatches).not.toBeNull();
    expect(urlMatches!.length).toBeGreaterThanOrEqual(4); // 4 Unix platforms
  });

  it("has sha256 fields for all platforms", () => {
    const sha256Matches = content.match(/^\s+sha256 "/gm);
    expect(sha256Matches).not.toBeNull();
    expect(sha256Matches!.length).toBeGreaterThanOrEqual(4);
  });

  it("has an install method", () => {
    expect(content).toContain("def install");
  });

  it("installs binary to bin/", () => {
    expect(content).toContain("bin.install");
  });

  it("has caveats method mentioning required dependencies", () => {
    expect(content).toContain("def caveats");
    expect(content).toContain("br");
    expect(content).toContain("ANTHROPIC_API_KEY");
  });

  it("has test block for brew test", () => {
    expect(content).toContain("test do");
    expect(content).toContain("--version");
  });
});

// ── Update workflow ───────────────────────────────────────────────────────────

describe("homebrew-tap update workflow", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    "homebrew-tap",
    ".github",
    "workflows",
    "update-formula.yml"
  );

  it("exists at homebrew-tap/.github/workflows/update-formula.yml", () => {
    expect(existsSync(workflowPath)).toBe(true);
  });

  it("triggers on repository_dispatch foreman-release event", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("repository_dispatch");
    expect(contents).toContain("foreman-release");
  });

  it("supports workflow_dispatch for manual updates", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("workflow_dispatch");
  });

  it("downloads checksums.txt from GitHub Release", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("checksums.txt");
    expect(contents).toContain("releases/download");
  });

  it("extracts SHA256 for all 4 Unix platforms", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("darwin-arm64");
    expect(contents).toContain("darwin-x64");
    expect(contents).toContain("linux-x64");
    expect(contents).toContain("linux-arm64");
  });

  it("updates the formula version", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("version");
    expect(contents).toContain("foreman.rb");
  });

  it("commits and pushes the updated formula", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("git commit");
    expect(contents).toContain("git push");
  });
});

// ── release-binaries.yml triggers homebrew update ────────────────────────────

describe("release-binaries.yml triggers Homebrew update", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    ".github",
    "workflows",
    "release-binaries.yml"
  );

  it("has a step to trigger Homebrew tap update", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("Homebrew");
    expect(contents).toContain("homebrew-tap");
  });

  it("uses repository-dispatch action", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("peter-evans/repository-dispatch");
  });

  it("dispatches foreman-release event type", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("foreman-release");
  });

  it("is skipped during dry run", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    // The homebrew dispatch step should be conditional on not dry_run
    const homebrewIdx = contents.indexOf("Homebrew tap update");
    const nearbyContent = contents.slice(homebrewIdx - 200, homebrewIdx + 500);
    expect(nearbyContent).toContain("dry_run");
  });
});

// ── release-binaries.yml checksums ───────────────────────────────────────────

describe("release-binaries.yml checksum generation", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    ".github",
    "workflows",
    "release-binaries.yml"
  );

  it("has a checksum generation step", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("checksums");
    expect(contents).toContain("sha256sum");
  });

  it("generates checksums.txt file", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("checksums.txt");
  });

  it("checksums step is in the create-release job", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    const createReleaseIdx = contents.indexOf("create-release:");
    const checksumsIdx = contents.indexOf("checksums.txt");
    // checksums.txt should appear after the create-release job definition
    expect(checksumsIdx).toBeGreaterThan(createReleaseIdx);
  });
});
