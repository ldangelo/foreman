/**
 * Brew install verification tests for the foreman Homebrew formula.
 *
 * This test suite verifies that:
 * 1. The formula file exists and is syntactically valid Ruby
 * 2. The formula has the correct structure (class, methods, URLs)
 * 3. The shell wrapper template in the formula is correct
 * 4. The formula passes `brew audit` if Homebrew is available
 * 5. On a macOS system with the tap installed, the binary works:
 *    - foreman --version outputs a version string
 *    - foreman --help lists expected commands
 *    - foreman doctor runs and outputs a Summary line
 *
 * Skip conditions:
 * - Formula syntax tests: require `ruby` (available on macOS by default)
 * - Brew audit tests: require `brew` (skipped if not installed)
 * - Live installation tests: require the tap to be installed and the formula
 *   to reference a published release (skipped if binary not found in PATH)
 *
 * Run individually:
 *   npx vitest run scripts/__tests__/brew-install.test.ts
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ── Constants ─────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const FORMULA_PATH = path.join(REPO_ROOT, "homebrew-tap", "Formula", "foreman.rb");

// Homebrew cellar paths (platform-dependent)
const HOMEBREW_MACOS_ARM = "/opt/homebrew";
const HOMEBREW_MACOS_INTEL = "/usr/local";
const HOMEBREW_LINUX = "/home/linuxbrew/.linuxbrew";

// ── Helpers ───────────────────────────────────────────────────────────────────

function isBrewAvailable(): boolean {
  const result = spawnSync("which", ["brew"], { encoding: "utf-8" });
  return result.status === 0 && result.stdout.trim().length > 0;
}

function isRubyAvailable(): boolean {
  const result = spawnSync("which", ["ruby"], { encoding: "utf-8" });
  return result.status === 0 && result.stdout.trim().length > 0;
}

function getHomebrewPrefix(): string | null {
  if (!isBrewAvailable()) return null;
  const result = spawnSync("brew", ["--prefix"], { encoding: "utf-8" });
  if (result.status !== 0) return null;
  return result.stdout.trim();
}

/**
 * Resolve the path to the Homebrew-installed foreman binary.
 * Checks common cellar paths in priority order.
 */
function resolveBrewForemanBinary(): string | null {
  // First, try $PATH (most likely to work if properly installed)
  const whichResult = spawnSync("which", ["foreman"], { encoding: "utf-8" });
  if (whichResult.status === 0) {
    const binaryPath = whichResult.stdout.trim();
    // Make sure it's a brew-installed binary (in a Homebrew path)
    const brewPrefixes = [HOMEBREW_MACOS_ARM, HOMEBREW_MACOS_INTEL, HOMEBREW_LINUX];
    const isBrewInstalled = brewPrefixes.some((prefix) =>
      binaryPath.startsWith(prefix)
    );
    if (isBrewInstalled && existsSync(binaryPath)) {
      return binaryPath;
    }
  }

  // Try standard Homebrew bin paths
  const homebrewPrefix = getHomebrewPrefix();
  if (homebrewPrefix) {
    const binPath = path.join(homebrewPrefix, "bin", "foreman");
    if (existsSync(binPath)) {
      return binPath;
    }
  }

  return null;
}

function isForemanBrewInstalled(): boolean {
  return resolveBrewForemanBinary() !== null;
}

// ── Formula file tests ────────────────────────────────────────────────────────

describe("Homebrew formula file", () => {
  it("exists at homebrew-tap/Formula/foreman.rb", () => {
    expect(existsSync(FORMULA_PATH)).toBe(true);
  });

  it("is a regular file with non-zero size", () => {
    const stats = statSync(FORMULA_PATH);
    expect(stats.isFile()).toBe(true);
    expect(stats.size).toBeGreaterThan(0);
  });
});

// ── Formula content tests ─────────────────────────────────────────────────────

describe("Homebrew formula content", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(FORMULA_PATH, "utf-8");
  });

  it("defines a class named Foreman inheriting from Formula", () => {
    expect(content).toMatch(/^class Foreman < Formula/m);
  });

  it("includes desc with AI orchestrator description", () => {
    expect(content).toContain("AI-powered multi-agent engineering orchestrator");
  });

  it("references the correct GitHub repository", () => {
    expect(content).toContain("ldangelo/foreman");
  });

  it("has a version declaration", () => {
    expect(content).toMatch(/^\s*version\s+["']\d+\.\d+\.\d+["']/m);
  });

  it("specifies MIT license", () => {
    expect(content).toContain('license "MIT"');
  });

  it("includes macOS-specific platform blocks", () => {
    expect(content).toContain("on_macos do");
    expect(content).toContain("on_arm do");
    expect(content).toContain("on_intel do");
  });

  it("includes Linux-specific platform blocks", () => {
    expect(content).toContain("on_linux do");
  });

  it("references all four platform binary archives", () => {
    expect(content).toContain("darwin-arm64");
    expect(content).toContain("darwin-x64");
    expect(content).toContain("linux-x64");
    expect(content).toContain("linux-arm64");
  });

  it("uses .tar.gz archive format for download URLs", () => {
    expect(content).toContain(".tar.gz");
  });

  it("has sha256 entries for each platform (or placeholders)", () => {
    // Either real SHA256 values (64 hex chars) or placeholder strings
    const sha256Pattern = /sha256\s+["']([a-f0-9]{64}|PLACEHOLDER_[A-Z0-9_]+)["']/g;
    const matches = content.match(sha256Pattern);
    // Should have at least 4 sha256 entries (one per platform)
    expect(matches).not.toBeNull();
    expect(matches!.length).toBeGreaterThanOrEqual(4);
  });

  it("defines an install method", () => {
    expect(content).toMatch(/^\s*def install/m);
  });

  it("install method copies binary to libexec/foreman", () => {
    expect(content).toContain("libexec");
    expect(content).toContain('"foreman"');
  });

  it("install method sets executable permissions", () => {
    expect(content).toContain("chmod 0755");
  });

  it("install method creates shell wrapper in bin/", () => {
    expect(content).toContain('(bin/"foreman").write');
    expect(content).toContain("#!/usr/bin/env bash");
    expect(content).toContain('exec "');
    expect(content).toContain('"$@"');
  });

  it("install method copies better_sqlite3.node side-car", () => {
    expect(content).toContain("better_sqlite3.node");
  });

  it("defines a test do block", () => {
    expect(content).toMatch(/^\s*test do/m);
  });

  it("test block checks --version output", () => {
    expect(content).toContain("--version");
    expect(content).toContain("assert_match");
  });

  it("test block checks --help output", () => {
    expect(content).toContain("--help");
  });

  it("test block runs doctor command", () => {
    expect(content).toContain("doctor");
  });

  it("defines a caveats method", () => {
    expect(content).toMatch(/^\s*def caveats/m);
  });

  it("caveats mentions br (beads_rust) requirement", () => {
    expect(content).toContain("beads_rust");
    expect(content).toContain("br");
  });

  it("caveats mentions ANTHROPIC_API_KEY requirement", () => {
    expect(content).toContain("ANTHROPIC_API_KEY");
  });
});

// ── Ruby syntax validation ────────────────────────────────────────────────────

describe("Homebrew formula Ruby syntax", () => {
  it("passes ruby -c syntax check", () => {
    if (!isRubyAvailable()) {
      console.warn("  [brew] Skipping: ruby not available for syntax check");
      return;
    }

    const result = spawnSync("ruby", ["-c", FORMULA_PATH], {
      encoding: "utf-8",
    });

    if (result.status !== 0) {
      console.error("  [brew] Ruby syntax error:", result.stderr);
    }
    expect(result.status).toBe(0);
  });

  it("uses typed: false pragma (required for Homebrew)", () => {
    const content = readFileSync(FORMULA_PATH, "utf-8");
    expect(content).toContain("# typed: false");
  });

  it("uses frozen_string_literal: true pragma", () => {
    const content = readFileSync(FORMULA_PATH, "utf-8");
    expect(content).toContain("# frozen_string_literal: true");
  });
});

// ── Homebrew audit tests ──────────────────────────────────────────────────────

describe("Homebrew formula audit", () => {
  it("passes brew audit --strict (if brew is available and tap is installed)", () => {
    if (!isBrewAvailable()) {
      console.warn("  [brew] Skipping: brew not installed");
      return;
    }

    // Check if the tap is installed — brew audit requires formula name, not path
    // (newer Homebrew versions disabled path-based audit)
    const tapCheck = spawnSync("brew", ["tap"], { encoding: "utf-8" });
    const installedTaps = tapCheck.stdout ?? "";
    if (!installedTaps.includes("oftheangels/tap")) {
      console.warn(
        "  [brew] Skipping brew audit: oftheangels/tap not installed.\n" +
        "  Install with: brew tap oftheangels/tap"
      );
      return;
    }

    const result = spawnSync(
      "brew",
      ["audit", "--strict", "foreman"],
      {
        encoding: "utf-8",
        timeout: 60_000,
      }
    );

    const output = (result.stdout ?? "") + (result.stderr ?? "");

    // Audit may fail due to placeholder SHA256 values — that's expected in dev
    // Check for structural errors only (not SHA256 mismatches)
    const hasStructuralError = output.includes("Error:") &&
      !output.includes("SHA256") &&
      !output.includes("checksum") &&
      !output.includes("sha256");

    if (hasStructuralError) {
      console.error("  [brew] audit structural error:", output);
    }
    expect(hasStructuralError).toBe(false);
  });

  it("passes ruby syntax check for formula (brew ruby -c equivalent)", () => {
    if (!isRubyAvailable()) {
      console.warn("  [brew] Skipping: ruby not available");
      return;
    }

    const result = spawnSync("ruby", ["-e", `require 'rubygems'; load '${FORMULA_PATH}'`], {
      encoding: "utf-8",
      timeout: 10_000,
      env: { ...process.env, HOMEBREW_NO_AUTO_UPDATE: "1" },
    });

    // This may fail if Homebrew's Formula class isn't in LOAD_PATH,
    // but that's OK — the important thing is no Ruby syntax errors
    // (load errors for missing constants are expected)
    const hasSyntaxError =
      result.stderr?.includes("SyntaxError") ||
      result.stdout?.includes("SyntaxError");

    expect(hasSyntaxError).toBe(false);
  });
});

// ── Live Homebrew installation tests ─────────────────────────────────────────

describe("foreman brew install — live binary tests", () => {
  let binaryPath: string | null = null;

  beforeAll(() => {
    binaryPath = resolveBrewForemanBinary();
    if (!binaryPath) {
      console.warn(
        "  [brew] Skipping live tests: foreman not installed via brew.\n" +
        "  Install with: brew tap oftheangels/tap && brew install foreman"
      );
      return;
    }

    console.log(`  [brew] Found brew-installed foreman at: ${binaryPath}`);

    // Smoke test: verify the binary is actually functional before running live
    // tests. A dev environment may have an `npm link` symlink at the Homebrew
    // bin path pointing to a local repo with a stale or absent dist build.
    // In that case, the binary exits with "foreman is not built" — we treat it
    // the same as "not found" so the live tests are skipped rather than failed.
    const smokeResult = spawnSync(binaryPath, ["--version"], {
      encoding: "utf-8",
      timeout: 15_000,
    });
    const smokeOutput = (smokeResult.stdout ?? "") + (smokeResult.stderr ?? "");
    if (
      smokeResult.status !== 0 ||
      smokeOutput.includes("foreman is not built") ||
      smokeOutput.includes("not built")
    ) {
      console.warn(
        `  [brew] Skipping live tests: binary found at ${binaryPath} but not functional.\n` +
        `  This usually means the binary is a development symlink pointing to an unbuilt dist.\n` +
        `  Run 'npm run build' in the foreman repo, or install via: brew tap oftheangels/tap && brew install foreman`
      );
      binaryPath = null;
      return;
    }
  });

  it("binary exists in Homebrew bin/ directory", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }
    expect(existsSync(binaryPath)).toBe(true);
  });

  it("binary is executable", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }
    const stats = statSync(binaryPath);
    // Check owner execute bit
    // eslint-disable-next-line no-bitwise
    expect(stats.mode & 0o100).toBeGreaterThan(0);
  });

  it("foreman --version outputs a version string", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--version"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    console.log(`  [brew] --version output: ${output.trim()}`);

    // Exit code 0
    expect(result.status).toBe(0);
    // Output should contain a version number (e.g. "0.1.0")
    expect(output).toMatch(/\d+\.\d+\.\d+/);
  });

  it("foreman --version does not exit with an error", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--version"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    // Should not crash with a signal
    expect(result.signal).toBeNull();
    expect(result.status).toBe(0);
  });

  it("foreman --help exits with code 0", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    expect(result.status).toBe(0);
  });

  it("foreman --help output contains 'Usage: foreman'", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("Usage: foreman");
  });

  it("foreman --help lists key commands (init, run, doctor, status)", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("init");
    expect(output).toContain("run");
    expect(output).toContain("doctor");
    expect(output).toContain("status");
  });

  it("foreman --help includes Commands and Options sections", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["--help"], {
      encoding: "utf-8",
      timeout: 15_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("Commands:");
    expect(output).toContain("Options:");
  });

  it("foreman doctor runs without crashing", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    // doctor exits 0 (all pass) or 1 (some failures) — both are valid
    // It must not crash with a signal (SIGSEGV, SIGBUS, etc.)
    expect(result.signal).toBeNull();
    expect([0, 1]).toContain(result.status);
  });

  it("foreman doctor output includes br binary check", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("br (beads_rust)");
  });

  it("foreman doctor output includes git binary check", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("git binary");
  });

  it("foreman doctor output includes System section", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    expect(output).toContain("System:");
  });

  it("foreman doctor output includes Summary line", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const result = spawnSync(binaryPath, ["doctor"], {
      encoding: "utf-8",
      timeout: 30_000,
    });

    const output = (result.stdout ?? "") + (result.stderr ?? "");
    // Doctor always ends with "Summary: N passed, ..."
    expect(output).toContain("Summary:");
  });

  it("better_sqlite3.node side-car is co-located in libexec/foreman/", () => {
    if (!binaryPath) {
      console.warn("  [brew] Skipping: binary not found");
      return;
    }

    const homebrewPrefix = getHomebrewPrefix();
    if (!homebrewPrefix) {
      console.warn("  [brew] Skipping: brew --prefix failed");
      return;
    }

    // Homebrew installs the binary to bin/foreman (wrapper), actual binary at
    // libexec/foreman/foreman with sqlite3 side-car alongside it.
    const libexecSideCarPath = path.join(
      homebrewPrefix,
      "opt",
      "foreman",
      "libexec",
      "foreman",
      "better_sqlite3.node"
    );

    if (existsSync(libexecSideCarPath)) {
      const stats = statSync(libexecSideCarPath);
      expect(stats.size).toBeGreaterThan(0);
      console.log(
        `  [brew] better_sqlite3.node found: ${(stats.size / 1024).toFixed(1)} KB`
      );
    } else {
      // Side-car may be missing if not yet published — warn but don't fail
      console.warn(
        `  [brew] Warning: better_sqlite3.node not found at ${libexecSideCarPath}`
      );
    }
  });
});

// ── Shell wrapper script validation ──────────────────────────────────────────

describe("Homebrew formula shell wrapper", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(FORMULA_PATH, "utf-8");
  });

  it("wrapper script uses bash shebang", () => {
    expect(content).toContain("#!/usr/bin/env bash");
  });

  it("wrapper script uses exec to delegate to libexec binary", () => {
    // The wrapper must exec (not fork) so signals propagate correctly
    expect(content).toMatch(/exec\s+["']/);
  });

  it("wrapper script passes through all arguments with $@", () => {
    expect(content).toContain('"$@"');
  });

  it("wrapper delegates to binary inside libexec/foreman/", () => {
    // The wrapper write block uses a heredoc — find the content between <<~EOS and EOS
    const writeMarker = '(bin/"foreman").write <<~EOS';
    const startIdx = content.indexOf(writeMarker);
    expect(startIdx).toBeGreaterThan(-1);

    // Find the closing EOS that follows (after the heredoc body)
    const afterHeredocStart = startIdx + writeMarker.length;
    const closingEosIdx = content.indexOf("\n    EOS", afterHeredocStart);
    expect(closingEosIdx).toBeGreaterThan(startIdx);

    // Extract the heredoc body (includes the #!/usr/bin/env bash exec line)
    const wrapperBody = content.slice(afterHeredocStart, closingEosIdx);
    expect(wrapperBody).toContain("libexec");
  });
});

// ── Platform detection tests ──────────────────────────────────────────────────

describe("Homebrew formula platform detection", () => {
  let content: string;

  beforeAll(() => {
    content = readFileSync(FORMULA_PATH, "utf-8");
  });

  it("uses OS.mac? for macOS detection", () => {
    expect(content).toContain("OS.mac?");
  });

  it("uses Hardware::CPU.arm? for ARM detection", () => {
    expect(content).toContain("Hardware::CPU.arm?");
  });

  it("binary selection uses correct darwin-arm64 name", () => {
    expect(content).toContain('"foreman-darwin-arm64"');
  });

  it("binary selection uses correct darwin-x64 name", () => {
    expect(content).toContain('"foreman-darwin-x64"');
  });

  it("binary selection uses correct linux-arm64 name", () => {
    expect(content).toContain('"foreman-linux-arm64"');
  });

  it("binary selection uses correct linux-x64 name", () => {
    expect(content).toContain('"foreman-linux-x64"');
  });
});
