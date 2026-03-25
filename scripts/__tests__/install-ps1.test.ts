/**
 * Tests for the install.ps1 PowerShell installer script (Windows).
 *
 * These tests verify the static content and structure of install.ps1
 * without actually downloading binaries or making network requests.
 * They check:
 * - The file exists at repo root and is readable
 * - Required PowerShell constructs are present
 * - OS/arch detection and platform guard are correct
 * - Asset naming convention matches release-binaries.yml
 * - Install directory logic is present
 * - Environment variable overrides are documented
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const INSTALL_PS1 = path.join(REPO_ROOT, "install.ps1");

// ── File existence ─────────────────────────────────────────────────────────────

describe("install.ps1 file", () => {
  it("exists at repo root", () => {
    expect(existsSync(INSTALL_PS1)).toBe(true);
  });

  it("is readable", () => {
    expect(() => readFileSync(INSTALL_PS1, "utf-8")).not.toThrow();
  });

  it("passes PowerShell syntax check (if pwsh is available)", () => {
    // Only run syntax check if pwsh is installed
    let pwshAvailable = false;
    try {
      execSync("pwsh -Version", { stdio: "pipe" });
      pwshAvailable = true;
    } catch {
      // pwsh not installed — skip this check
    }

    if (pwshAvailable) {
      expect(() => {
        execSync(
          `pwsh -NoProfile -NonInteractive -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('${INSTALL_PS1}', [ref]$null, [ref]$null) }"`,
          { stdio: "pipe" }
        );
      }).not.toThrow();
    }
  });
});

// ── Script content ────────────────────────────────────────────────────────────

describe("install.ps1 content", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(INSTALL_PS1, "utf-8");
  });

  it("targets the correct GitHub repository", () => {
    expect(content).toContain("ldangelo/foreman");
  });

  it("uses GitHub API to fetch latest release", () => {
    expect(content).toContain("api.github.com");
    expect(content).toContain("releases/latest");
  });

  it("installs to %LOCALAPPDATA%\\foreman by default", () => {
    expect(content).toContain("LOCALAPPDATA");
    expect(content).toContain("foreman");
  });

  it("installs the binary as foreman.exe", () => {
    expect(content).toContain("foreman.exe");
  });

  it("constructs correct asset name matching release workflow", () => {
    // Asset format from release-binaries.yml: foreman-{TAG}-win-x64.zip
    expect(content).toContain("win-x64.zip");
    expect(content).toContain("foreman-$version-win-x64.zip");
  });

  it("downloads the correct binary from the archive", () => {
    expect(content).toContain("foreman-win-x64.exe");
  });

  it("adds install directory to user PATH via SetEnvironmentVariable", () => {
    expect(content).toContain("SetEnvironmentVariable");
    expect(content).toContain("User");
  });

  it("verifies installation with foreman --version", () => {
    expect(content).toContain("--version");
  });

  it("cleans up temp directory in a finally block", () => {
    expect(content).toContain("finally");
    expect(content).toContain("Remove-Item");
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

  it("rejects non-Windows platforms with helpful error message pointing to install.sh", () => {
    expect(content).toContain("install.sh");
    expect(content).toContain("Windows");
  });

  it("uses Invoke-WebRequest for downloads", () => {
    expect(content).toContain("Invoke-WebRequest");
  });

  it("uses Expand-Archive for ZIP extraction", () => {
    expect(content).toContain("Expand-Archive");
  });

  it("uses Invoke-RestMethod for GitHub API call", () => {
    expect(content).toContain("Invoke-RestMethod");
  });

  it("sets $ErrorActionPreference to Stop for strict error handling", () => {
    expect(content).toContain("$ErrorActionPreference = 'Stop'");
  });

  it("requires PowerShell 5.0+", () => {
    expect(content).toContain("#Requires -Version 5.0");
  });

  it("handles rate limiting with helpful message", () => {
    expect(content).toContain("rate limit");
  });

  it("validates version format starts with 'v'", () => {
    expect(content).toContain("^v");
  });

  it("uses Test-Path for file/directory existence checks", () => {
    expect(content).toContain("Test-Path");
  });

  it("uses New-Item to create install directory", () => {
    expect(content).toContain("New-Item");
    expect(content).toContain("Directory");
  });

  it("uses Copy-Item to install the binary", () => {
    expect(content).toContain("Copy-Item");
  });

  it("uses Join-Path for path construction", () => {
    expect(content).toContain("Join-Path");
  });

  it("notifies user that a new terminal may be needed after PATH change", () => {
    // The message may span multiple lines in the script source
    expect(content).toMatch(/open a new|new.*terminal|new.*window|new.*PowerShell/is);
  });
});

// ── Asset naming consistency with release workflow ─────────────────────────────

describe("install.ps1 asset naming matches release-binaries.yml", () => {
  let installContent: string;
  let workflowContent: string;

  beforeAll(() => {
    installContent = readFileSync(INSTALL_PS1, "utf-8");
    const workflowPath = path.join(
      REPO_ROOT,
      ".github",
      "workflows",
      "release-binaries.yml"
    );
    workflowContent = readFileSync(workflowPath, "utf-8");
  });

  it("workflow produces .zip archive for Windows platform", () => {
    expect(workflowContent).toContain("win-x64");
    expect(workflowContent).toContain(".zip");
  });

  it("install.ps1 downloads .zip archive", () => {
    expect(installContent).toContain(".zip");
  });

  it("workflow names the Windows archive foreman-{TAG}-win-x64.zip", () => {
    expect(workflowContent).toContain("foreman-${TAG}-${target}.zip");
  });

  it("install.ps1 constructs matching archive name foreman-{version}-win-x64.zip", () => {
    expect(installContent).toContain("foreman-$version-win-x64.zip");
  });

  it("workflow binary inside archive is foreman-win-x64.exe", () => {
    expect(workflowContent).toContain("win-x64");
    expect(workflowContent).toContain(".exe");
  });

  it("install.ps1 looks for foreman-win-x64.exe inside the extracted archive", () => {
    expect(installContent).toContain("foreman-win-x64.exe");
  });
});
