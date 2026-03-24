/**
 * Integration test: npm pack produces a valid, installable package.
 *
 * Verifies the full distribution chain:
 * 1. `npm pack` runs successfully and creates a tarball
 * 2. Tarball contains all required files (bin, dist, defaults)
 * 3. `foreman --help` works from within the extracted package
 *
 * ⚠️  REQUIRES a built dist/ directory. Run `npm run build` first.
 *     Test is automatically skipped when dist/ is absent.
 */
import { describe, it, expect, afterEach } from "vitest";
import { execSync, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  rmSync,
  existsSync,
  statSync,
  readFileSync,
  symlinkSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = join(__dirname, "../../..");
const DIST_CLI = join(REPO_ROOT, "dist", "cli", "index.js");
const PACKAGE_JSON_PATH = join(REPO_ROOT, "package.json");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Read version from package.json (avoids hardcoding). */
function readPackageVersion(): string {
  const pkg = JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf-8")) as {
    version: string;
  };
  return pkg.version;
}

/**
 * Run `npm pack` in REPO_ROOT and return the path to the generated tarball.
 * npm pack --json outputs a JSON array of packed files; we use --dry-run first
 * to get the filename, then run the real pack.
 */
function runNpmPack(destDir: string): string {
  // npm pack with --pack-destination writes the tarball to destDir
  const result = spawnSync(
    "npm",
    ["pack", "--pack-destination", destDir, "--json"],
    {
      cwd: REPO_ROOT,
      encoding: "utf-8",
      timeout: 60_000,
    }
  );

  if (result.status !== 0) {
    throw new Error(
      `npm pack failed (status ${result.status}):\n${result.stderr}`
    );
  }

  const jsonOutput = result.stdout.trim();
  const packed = JSON.parse(jsonOutput) as Array<{ filename: string }>;
  if (!packed.length) {
    throw new Error("npm pack produced no output");
  }

  return join(destDir, packed[0].filename);
}

/** Extract tarball using tar (available on macOS/Linux CI; also Windows 10+). */
function extractTarball(tarball: string, destDir: string): void {
  execSync(`tar -xzf "${tarball}" -C "${destDir}"`, { timeout: 30_000 });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("npm pack integration", () => {
  let tempDir: string | undefined;

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) {
      rmSync(tempDir, { recursive: true, force: true });
    }
    tempDir = undefined;
  });

  it("skips gracefully when dist/ is not built", () => {
    if (existsSync(DIST_CLI)) {
      // dist IS built — nothing to test here, skip via early return
      return;
    }
    console.warn(
      "npm-pack test: dist/cli/index.js not found — run `npm run build` to enable this test"
    );
    expect(true).toBe(true); // Explicit pass so the test isn't red
  });

  it(
    "npm pack creates a non-empty tarball",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return; // skip — dist not built
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);

      expect(existsSync(tarball)).toBe(true);

      const { size } = statSync(tarball);
      // Tarball must be at least 100 KB (dist/ + assets included)
      expect(size).toBeGreaterThan(100 * 1024);
      // Tarball should not be absurdly large (no accidental node_modules)
      expect(size).toBeLessThan(50 * 1024 * 1024);
    }
  );

  it(
    "tarball filename matches package name and version",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      const version = readPackageVersion();
      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);

      // npm converts @scope/name → scope-name, so @oftheangels/foreman → oftheangels-foreman
      const expectedPattern = new RegExp(
        `oftheangels-foreman-${version}\\.tgz$`
      );
      expect(tarball).toMatch(expectedPattern);
    }
  );

  it(
    "extracted package contains bin/foreman",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      // npm pack always extracts to a "package/" subdirectory
      const binForeman = join(tempDir, "package", "bin", "foreman");
      expect(existsSync(binForeman)).toBe(true);

      // Should have correct shebang
      const content = readFileSync(binForeman, "utf-8");
      expect(content.startsWith("#!/usr/bin/env node")).toBe(true);
    }
  );

  it(
    "extracted package contains dist/cli/index.js",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const distCli = join(tempDir, "package", "dist", "cli", "index.js");
      expect(existsSync(distCli)).toBe(true);
    }
  );

  it(
    "extracted package contains dist/defaults/workflows/default.yaml",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const defaultWorkflow = join(
        tempDir,
        "package",
        "dist",
        "defaults",
        "workflows",
        "default.yaml"
      );
      expect(existsSync(defaultWorkflow)).toBe(true);
    }
  );

  it(
    "extracted package contains dist/defaults/prompts/default/explorer.md",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const explorerPrompt = join(
        tempDir,
        "package",
        "dist",
        "defaults",
        "prompts",
        "default",
        "explorer.md"
      );
      expect(existsSync(explorerPrompt)).toBe(true);
    }
  );

  it(
    "extracted package contains src/defaults/ (for runtime fallback)",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      // package.json "files" includes src/defaults/ — verify it's present
      const srcDefaults = join(tempDir, "package", "src", "defaults");
      expect(existsSync(srcDefaults)).toBe(true);

      const srcWorkflow = join(srcDefaults, "workflows", "default.yaml");
      expect(existsSync(srcWorkflow)).toBe(true);
    }
  );

  it(
    "bin/foreman has executable permissions in extracted package (Unix)",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }
      if (process.platform === "win32") {
        return; // Not meaningful on Windows
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const binForeman = join(tempDir, "package", "bin", "foreman");
      const { mode } = statSync(binForeman);
      const isExecutable = (mode & 0o111) !== 0;
      expect(isExecutable).toBe(true);
    }
  );

  it(
    "foreman --help works from extracted package",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const pkgDir = join(tempDir, "package");
      const binForeman = join(pkgDir, "bin", "foreman");

      // Symlink the repo's node_modules into the extracted package so that
      // the CLI's imports resolve correctly without a full `npm install`.
      // This simulates an installed package that has its dependencies available.
      const repoNodeModules = join(REPO_ROOT, "node_modules");
      const pkgNodeModules = join(pkgDir, "node_modules");
      if (existsSync(repoNodeModules) && !existsSync(pkgNodeModules)) {
        symlinkSync(repoNodeModules, pkgNodeModules);
      }

      // Run `node bin/foreman --help` from inside the extracted package directory
      const result = spawnSync(
        process.execPath, // node
        [binForeman, "--help"],
        {
          cwd: pkgDir,
          encoding: "utf-8",
          timeout: 30_000,
          env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
        }
      );

      const output = (result.stdout ?? "") + (result.stderr ?? "");

      // Help text must contain usage line
      expect(output).toContain("Usage: foreman");
      // Should not crash with module not found
      expect(output).not.toContain("ERR_MODULE_NOT_FOUND");
      // Exit code: commander writes --help to stdout and exits 0
      expect(result.status).toBe(0);
    }
  );

  it(
    "extracted package does not include node_modules",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      const tarball = runNpmPack(tempDir);
      extractTarball(tarball, tempDir);

      const nodeModules = join(tempDir, "package", "node_modules");
      expect(existsSync(nodeModules)).toBe(false);
    }
  );
});
