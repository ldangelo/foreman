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
import { describe, it, expect, afterEach, beforeAll, afterAll } from "vitest";
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
  const npmCacheDir = join(destDir, ".npm-cache");
  // npm pack with --pack-destination writes the tarball to destDir
  const result = spawnSync(
    "npm",
    ["pack", "--pack-destination", destDir, "--json"],
    {
      cwd: REPO_ROOT,
      encoding: "utf-8",
      timeout: 120_000,
      env: {
        ...process.env,
        npm_config_cache: npmCacheDir,
      },
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
  let packDir: string | undefined;
  let packedTarball: string | undefined;

  function getPackedTarball(): string {
    if (!packedTarball) {
      throw new Error("packed tarball not prepared");
    }
    return packedTarball;
  }

  beforeAll(() => {
    if (!existsSync(DIST_CLI)) {
      return;
    }
    packDir = mkdtempSync(join(tmpdir(), "foreman-pack-tarball-"));
    packedTarball = runNpmPack(packDir);
  }, 120_000);

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) {
      rmSync(tempDir, { recursive: true, force: true });
    }
    tempDir = undefined;
  });

  afterAll(() => {
    if (packDir && existsSync(packDir)) {
      rmSync(packDir, { recursive: true, force: true });
    }
    packDir = undefined;
    packedTarball = undefined;
  });

  it("skips gracefully when dist/ is not built", () => {
    if (existsSync(DIST_CLI)) {
      return;
    }
    console.warn(
      "npm-pack test: dist/cli/index.js not found — run `npm run build` to enable this test"
    );
    expect(true).toBe(true);
  });

  it(
    "npm pack creates a non-empty tarball",
    { timeout: 90_000 },
    () => {
      if (!existsSync(DIST_CLI)) {
        return;
      }

      const tarball = getPackedTarball();
      expect(existsSync(tarball)).toBe(true);

      const { size } = statSync(tarball);
      expect(size).toBeGreaterThan(100 * 1024);
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
      const tarball = getPackedTarball();

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
      extractTarball(getPackedTarball(), tempDir);

      const binForeman = join(tempDir, "package", "bin", "foreman");
      expect(existsSync(binForeman)).toBe(true);

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
      extractTarball(getPackedTarball(), tempDir);

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
      extractTarball(getPackedTarball(), tempDir);

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
      extractTarball(getPackedTarball(), tempDir);

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
      extractTarball(getPackedTarball(), tempDir);

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
        return;
      }

      tempDir = mkdtempSync(join(tmpdir(), "foreman-pack-"));
      extractTarball(getPackedTarball(), tempDir);

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
      extractTarball(getPackedTarball(), tempDir);

      const pkgDir = join(tempDir, "package");
      const binForeman = join(pkgDir, "bin", "foreman");

      const repoNodeModules = join(REPO_ROOT, "node_modules");
      const pkgNodeModules = join(pkgDir, "node_modules");
      if (existsSync(repoNodeModules) && !existsSync(pkgNodeModules)) {
        symlinkSync(repoNodeModules, pkgNodeModules);
      }

      const result = spawnSync(
        process.execPath,
        [binForeman, "--help"],
        {
          cwd: pkgDir,
          encoding: "utf-8",
          timeout: 30_000,
          env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
        }
      );

      const output = (result.stdout ?? "") + (result.stderr ?? "");

      expect(output).toContain("Usage: foreman");
      expect(output).not.toContain("ERR_MODULE_NOT_FOUND");
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
      extractTarball(getPackedTarball(), tempDir);

      const nodeModules = join(tempDir, "package", "node_modules");
      expect(existsSync(nodeModules)).toBe(false);
    }
  );
});
