/**
 * Tests for the install.sh curl installer script.
 *
 * These tests verify the static content and structure of install.sh
 * without actually downloading binaries or making network requests.
 * They check:
 * - The file exists at repo root and is executable
 * - Required shell constructs are present (shebang, set -eu, etc.)
 * - OS/arch detection patterns are correct
 * - Asset naming convention matches release-binaries.yml
 * - Install directory logic is present
 * - Environment variable overrides are documented
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const INSTALL_SH = path.join(REPO_ROOT, "install.sh");

// ── File existence & permissions ──────────────────────────────────────────────

describe("install.sh file", () => {
  it("exists at repo root", () => {
    expect(existsSync(INSTALL_SH)).toBe(true);
  });

  it("is executable", () => {
    const stats = statSync(INSTALL_SH);
    // Check owner execute bit (S_IXUSR = 0o100)
    // eslint-disable-next-line no-bitwise
    expect(stats.mode & 0o100).toBeGreaterThan(0);
  });

  it("passes sh syntax check", () => {
    expect(() => {
      execSync(`sh -n "${INSTALL_SH}"`, { stdio: "pipe" });
    }).not.toThrow();
  });
});

// ── Script content ────────────────────────────────────────────────────────────

describe("install.sh content", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(INSTALL_SH, "utf-8");
  });

  it("starts with #!/bin/sh shebang", () => {
    expect(content.startsWith("#!/bin/sh")).toBe(true);
  });

  it("uses set -eu for strict error handling", () => {
    expect(content).toMatch(/^set\s+-eu/m);
  });

  it("targets the correct GitHub repository", () => {
    expect(content).toContain('REPO="ldangelo/foreman"');
  });

  it("uses GitHub API to fetch latest release", () => {
    expect(content).toContain("api.github.com");
    expect(content).toContain("releases/latest");
  });

  it("detects darwin and linux OS", () => {
    expect(content).toContain("Darwin");
    expect(content).toContain("Linux");
    expect(content).toContain('"darwin"');
    expect(content).toContain('"linux"');
  });

  it("detects arm64 architecture including aarch64", () => {
    expect(content).toContain("arm64");
    expect(content).toContain("aarch64");
  });

  it("normalizes x86_64 to x64", () => {
    expect(content).toContain("x86_64");
    expect(content).toContain('"x64"');
  });

  it("constructs correct asset name matching release workflow", () => {
    // Asset format from release-binaries.yml: foreman-{TAG}-{platform}-{arch}.tar.gz
    expect(content).toContain('asset_name="foreman-${version}-${platform}.tar.gz"');
  });

  it("installs to /usr/local/bin as primary target", () => {
    expect(content).toContain("/usr/local/bin");
  });

  it("falls back to ~/.local/bin when sudo unavailable", () => {
    expect(content).toContain("/.local/bin");
  });

  it("verifies installation with foreman --version", () => {
    expect(content).toContain("--version");
  });

  it("installs better_sqlite3.node side-car alongside binary", () => {
    expect(content).toContain("better_sqlite3.node");
  });

  it("cleans up temp directory on exit", () => {
    expect(content).toContain("trap cleanup");
    expect(content).toContain("rm -rf");
  });

  it("supports FOREMAN_VERSION environment variable override", () => {
    expect(content).toContain("FOREMAN_VERSION");
  });

  it("supports FOREMAN_INSTALL environment variable override", () => {
    expect(content).toContain("FOREMAN_INSTALL");
  });

  it("supports GITHUB_TOKEN for API authentication", () => {
    expect(content).toContain("GITHUB_TOKEN");
  });

  it("rejects Windows with helpful error message", () => {
    expect(content).toContain("install.ps1");
    expect(content).toContain("Windows");
  });

  it("uses curl with -fsSL flags", () => {
    // -f = fail on HTTP errors, -s = silent, -S = show errors, -L = follow redirects
    expect(content).toMatch(/curl\s+-fsSL/);
  });

  it("uses tar xzf for extraction", () => {
    expect(content).toMatch(/tar\s+xzf/);
  });

  it("requires curl, tar, and uname", () => {
    expect(content).toContain("require_tool curl");
    expect(content).toContain("require_tool tar");
    expect(content).toContain("require_tool uname");
  });

  it("handles rate limiting with helpful message", () => {
    expect(content).toContain("rate limit");
  });

  it("provides a macOS Gatekeeper note", () => {
    expect(content).toContain("quarantine");
  });
});

// ── Asset naming consistency with release workflow ─────────────────────────────

describe("install.sh asset naming matches release-binaries.yml", () => {
  let installContent: string;
  let workflowContent: string;

  beforeAll(() => {
    installContent = readFileSync(INSTALL_SH, "utf-8");
    const workflowPath = path.join(
      REPO_ROOT,
      ".github",
      "workflows",
      "release-binaries.yml"
    );
    workflowContent = readFileSync(workflowPath, "utf-8");
  });

  it("workflow produces .tar.gz archives for Unix platforms", () => {
    // release-binaries.yml creates tar.gz for non-Windows
    expect(workflowContent).toContain(".tar.gz");
    expect(workflowContent).toContain('foreman-${TAG}-${target}.tar.gz');
  });

  it("install.sh downloads .tar.gz archives", () => {
    expect(installContent).toContain(".tar.gz");
  });

  it("install.sh platform naming uses lowercase (darwin/linux)", () => {
    // uname -s returns 'Darwin'/'Linux'; script maps to lowercase
    expect(installContent).toContain('"darwin"');
    expect(installContent).toContain('"linux"');
  });
});
