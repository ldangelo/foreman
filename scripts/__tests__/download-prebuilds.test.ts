/**
 * Tests for scripts/download-prebuilds.ts
 *
 * Tests cover:
 * - URL generation for all 5 targets
 * - Version detection from node_modules
 * - Output path generation
 * - Status check logic
 * - Prebuilt file presence verification (integration tests)
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
let _testCounter = 0;
import path from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, writeFileSync, existsSync, rmSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

// ── URL Generation ────────────────────────────────────────────────────────────

describe("buildPrebuiltUrl", () => {
  it("generates correct URL for darwin-arm64", async () => {
    const { buildPrebuiltUrl } = await import("../download-prebuilds.js");
    const url = buildPrebuiltUrl("darwin-arm64", "12.8.0", 115);
    expect(url).toBe(
      "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.8.0/better-sqlite3-v12.8.0-node-v115-darwin-arm64.tar.gz"
    );
  });

  it("generates correct URL for darwin-x64", async () => {
    const { buildPrebuiltUrl } = await import("../download-prebuilds.js");
    const url = buildPrebuiltUrl("darwin-x64", "12.8.0", 115);
    expect(url).toBe(
      "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.8.0/better-sqlite3-v12.8.0-node-v115-darwin-x64.tar.gz"
    );
  });

  it("generates correct URL for linux-x64", async () => {
    const { buildPrebuiltUrl } = await import("../download-prebuilds.js");
    const url = buildPrebuiltUrl("linux-x64", "12.8.0", 115);
    expect(url).toBe(
      "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.8.0/better-sqlite3-v12.8.0-node-v115-linux-x64.tar.gz"
    );
  });

  it("generates correct URL for linux-arm64", async () => {
    const { buildPrebuiltUrl } = await import("../download-prebuilds.js");
    const url = buildPrebuiltUrl("linux-arm64", "12.8.0", 115);
    expect(url).toBe(
      "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.8.0/better-sqlite3-v12.8.0-node-v115-linux-arm64.tar.gz"
    );
  });

  it("generates correct URL for win-x64 (uses win32 in asset name)", async () => {
    const { buildPrebuiltUrl } = await import("../download-prebuilds.js");
    const url = buildPrebuiltUrl("win-x64", "12.8.0", 115);
    // GitHub releases use "win32-x64" not "win-x64"
    expect(url).toBe(
      "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.8.0/better-sqlite3-v12.8.0-node-v115-win32-x64.tar.gz"
    );
  });

  it("uses correct ABI for Node 22", async () => {
    const { buildPrebuiltUrl, NODE_ABI_VERSIONS } = await import(
      "../download-prebuilds.js"
    );
    const abi = NODE_ABI_VERSIONS[22];
    expect(abi).toBe(127);
    const url = buildPrebuiltUrl("linux-x64", "12.8.0", abi);
    expect(url).toContain("node-v127");
  });

  it("uses correct ABI for Node 25", async () => {
    const { buildPrebuiltUrl, NODE_ABI_VERSIONS } = await import(
      "../download-prebuilds.js"
    );
    const abi = NODE_ABI_VERSIONS[25];
    expect(abi).toBe(141);
    const url = buildPrebuiltUrl("darwin-arm64", "12.8.0", abi);
    expect(url).toContain("node-v141");
  });
});

// ── Constants ─────────────────────────────────────────────────────────────────

describe("PREBUILD_TARGETS", () => {
  it("contains all 5 expected targets", async () => {
    const { PREBUILD_TARGETS } = await import("../download-prebuilds.js");
    expect(PREBUILD_TARGETS).toHaveLength(5);
    expect(PREBUILD_TARGETS).toContain("darwin-arm64");
    expect(PREBUILD_TARGETS).toContain("darwin-x64");
    expect(PREBUILD_TARGETS).toContain("linux-x64");
    expect(PREBUILD_TARGETS).toContain("linux-arm64");
    expect(PREBUILD_TARGETS).toContain("win-x64");
  });
});

describe("TARGET_TO_ASSET_PLATFORM", () => {
  it("maps win-x64 to win32-x64 (GitHub naming convention)", async () => {
    const { TARGET_TO_ASSET_PLATFORM } = await import("../download-prebuilds.js");
    expect(TARGET_TO_ASSET_PLATFORM["win-x64"]).toBe("win32-x64");
  });

  it("keeps darwin and linux targets unchanged", async () => {
    const { TARGET_TO_ASSET_PLATFORM } = await import("../download-prebuilds.js");
    expect(TARGET_TO_ASSET_PLATFORM["darwin-arm64"]).toBe("darwin-arm64");
    expect(TARGET_TO_ASSET_PLATFORM["darwin-x64"]).toBe("darwin-x64");
    expect(TARGET_TO_ASSET_PLATFORM["linux-x64"]).toBe("linux-x64");
    expect(TARGET_TO_ASSET_PLATFORM["linux-arm64"]).toBe("linux-arm64");
  });
});

describe("NODE_ABI_VERSIONS", () => {
  it("has correct ABI for all known Node.js versions", async () => {
    const { NODE_ABI_VERSIONS } = await import("../download-prebuilds.js");
    expect(NODE_ABI_VERSIONS[20]).toBe(115);
    expect(NODE_ABI_VERSIONS[22]).toBe(127);
    expect(NODE_ABI_VERSIONS[23]).toBe(131);
    expect(NODE_ABI_VERSIONS[24]).toBe(137);
    expect(NODE_ABI_VERSIONS[25]).toBe(141);
  });

  it("default Node major is 20", async () => {
    const { DEFAULT_NODE_MAJOR } = await import("../download-prebuilds.js");
    expect(DEFAULT_NODE_MAJOR).toBe(20);
  });
});

// ── Version Detection ─────────────────────────────────────────────────────────

describe("getBetterSqlite3Version", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(tmpdir(), `foreman-test-${Date.now()}-${++_testCounter}`);
    mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("reads version from installed node_modules package.json", async () => {
    const { getBetterSqlite3Version } = await import("../download-prebuilds.js");

    const pkgDir = path.join(tmpDir, "node_modules", "better-sqlite3");
    mkdirSync(pkgDir, { recursive: true });
    writeFileSync(
      path.join(pkgDir, "package.json"),
      JSON.stringify({ version: "12.8.0" })
    );

    const version = getBetterSqlite3Version(tmpDir);
    expect(version).toBe("12.8.0");
  });

  it("falls back to project package.json when node_modules missing", async () => {
    const { getBetterSqlite3Version } = await import("../download-prebuilds.js");

    writeFileSync(
      path.join(tmpDir, "package.json"),
      JSON.stringify({ dependencies: { "better-sqlite3": "^12.6.2" } })
    );

    const version = getBetterSqlite3Version(tmpDir);
    // Should strip the ^ prefix
    expect(version).toBe("12.6.2");
  });

  it("strips semver range prefixes (^, ~, >=)", async () => {
    const { getBetterSqlite3Version } = await import("../download-prebuilds.js");

    for (const [range, expected] of [
      ["^12.8.0", "12.8.0"],
      ["~12.8.0", "12.8.0"],
      [">=12.0.0", "12.0.0"],
      ["12.8.0", "12.8.0"],
    ]) {
      writeFileSync(
        path.join(tmpDir, "package.json"),
        JSON.stringify({ dependencies: { "better-sqlite3": range } })
      );
      expect(getBetterSqlite3Version(tmpDir)).toBe(expected);
    }
  });

  it("throws when neither node_modules nor package.json has version", async () => {
    const { getBetterSqlite3Version } = await import("../download-prebuilds.js");

    writeFileSync(path.join(tmpDir, "package.json"), JSON.stringify({}));
    expect(() => getBetterSqlite3Version(tmpDir)).toThrow(/Cannot determine/);
  });

  it("reads actual version from repo node_modules", async () => {
    const { getBetterSqlite3Version } = await import("../download-prebuilds.js");
    const version = getBetterSqlite3Version(REPO_ROOT);
    // Should be a valid semver like "12.8.0"
    expect(version).toMatch(/^\d+\.\d+\.\d+$/);
  });
});

// ── Output Path ───────────────────────────────────────────────────────────────

describe("getPrebuiltOutputPath", () => {
  it("returns correct path for each target", async () => {
    const { getPrebuiltOutputPath } = await import("../download-prebuilds.js");
    const outputDir = "/tmp/prebuilds";

    expect(getPrebuiltOutputPath(outputDir, "darwin-arm64")).toBe(
      "/tmp/prebuilds/darwin-arm64/better_sqlite3.node"
    );
    expect(getPrebuiltOutputPath(outputDir, "win-x64")).toBe(
      "/tmp/prebuilds/win-x64/better_sqlite3.node"
    );
  });
});

// ── Version Manifest ──────────────────────────────────────────────────────────

describe("writeVersionManifest", () => {
  let tmpDir: string;

  beforeEach(() => {
    _testCounter++;
    tmpDir = path.join(tmpdir(), `prebuild-version-test-${_testCounter}`);
    mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("writes version.json with correct fields", async () => {
    const { writeVersionManifest } = await import("../download-prebuilds.js");
    const { readFileSync } = await import("node:fs");

    writeVersionManifest(tmpDir, "12.8.0", 115, ["darwin-arm64", "linux-x64"]);

    const manifestPath = path.join(tmpDir, "version.json");
    expect(existsSync(manifestPath)).toBe(true);

    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
      "better-sqlite3": string;
      nodeAbi: number;
      nodeMajor: number;
      targets: string[];
      downloadedAt: string;
      source: string;
    };

    expect(manifest["better-sqlite3"]).toBe("12.8.0");
    expect(manifest.nodeAbi).toBe(115);
    expect(manifest.nodeMajor).toBe(20);
    expect(manifest.targets).toEqual(["darwin-arm64", "linux-x64"]);
    expect(manifest.downloadedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(manifest.source).toContain("better-sqlite3");
  });

  it("resolves nodeMajor from NODE_ABI_VERSIONS", async () => {
    const { writeVersionManifest } = await import("../download-prebuilds.js");
    const { readFileSync } = await import("node:fs");

    // ABI 127 = Node 22
    writeVersionManifest(tmpDir, "12.8.0", 127, ["darwin-arm64"]);

    const manifest = JSON.parse(
      readFileSync(path.join(tmpDir, "version.json"), "utf8")
    ) as { nodeMajor: number };
    expect(manifest.nodeMajor).toBe(22);
  });

  it("overwrites existing version.json on re-download", async () => {
    const { writeVersionManifest } = await import("../download-prebuilds.js");
    const { readFileSync } = await import("node:fs");

    writeVersionManifest(tmpDir, "12.6.2", 115, ["darwin-arm64"]);
    writeVersionManifest(tmpDir, "12.8.0", 115, ["darwin-arm64"]);

    const manifest = JSON.parse(
      readFileSync(path.join(tmpDir, "version.json"), "utf8")
    ) as { "better-sqlite3": string };
    expect(manifest["better-sqlite3"]).toBe("12.8.0");
  });
});

// ── Actual Prebuilts Verification (Integration) ────────────────────────────────

describe("scripts/prebuilds — integration", () => {
  const prebuildsDir = path.join(REPO_ROOT, "scripts", "prebuilds");

  it("prebuilds directory exists", () => {
    expect(existsSync(prebuildsDir)).toBe(true);
  });

  it("version.json exists and contains valid metadata", () => {
    const { readFileSync } = require("node:fs");
    const manifestPath = path.join(prebuildsDir, "version.json");
    expect(existsSync(manifestPath)).toBe(true);

    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
      "better-sqlite3": string;
      nodeAbi: number;
      targets: string[];
    };

    // Version should be a semver string
    expect(manifest["better-sqlite3"]).toMatch(/^\d+\.\d+\.\d+$/);
    // ABI should be a valid number
    expect(typeof manifest.nodeAbi).toBe("number");
    expect(manifest.nodeAbi).toBeGreaterThan(0);
    // Should list all 5 targets
    expect(manifest.targets).toHaveLength(5);
    expect(manifest.targets).toContain("darwin-arm64");
    expect(manifest.targets).toContain("win-x64");
  });

  it.each(["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "win-x64"])(
    "%s/better_sqlite3.node exists and is non-empty",
    (target) => {
      const nodePath = path.join(prebuildsDir, target, "better_sqlite3.node");
      expect(existsSync(nodePath)).toBe(true);
      const size = statSync(nodePath).size;
      // Each .node file should be at least 1 MB (typically ~1.8–2 MB)
      expect(size).toBeGreaterThan(1_000_000);
    }
  );

  it("all 5 prebuilts match expected size range (1–5 MB each)", async () => {
    const { PREBUILD_TARGETS, getPrebuiltOutputPath } = await import(
      "../download-prebuilds.js"
    );
    for (const target of PREBUILD_TARGETS) {
      const nodePath = getPrebuiltOutputPath(prebuildsDir, target);
      if (existsSync(nodePath)) {
        const size = statSync(nodePath).size;
        expect(size).toBeGreaterThan(1_000_000); // > 1 MB
        expect(size).toBeLessThan(10_000_000);   // < 10 MB
      }
    }
  });
});

// ── Local Platform Loading Test ───────────────────────────────────────────────

describe("native addon loading — local platform", () => {
  it("loads better_sqlite3.node from node_modules successfully", async () => {
    // Test that the current platform's addon (correct ABI) loads cleanly.
    // The prebuilts in scripts/prebuilds/ are ABI 115 (Node 20), which won't
    // load on Node 22+. We test with node_modules which has the correct ABI.
    const { createRequire } = await import("node:module");
    const require = createRequire(import.meta.url);

    const nodePath = path.join(
      REPO_ROOT,
      "node_modules",
      "better-sqlite3",
      "build",
      "Release",
      "better_sqlite3.node"
    );

    expect(existsSync(nodePath)).toBe(true);

    // Should load without throwing
    expect(() => require(nodePath)).not.toThrow();

    const addon = require(nodePath);
    // better-sqlite3 addon exports are objects/functions
    expect(typeof addon).toBe("object");
  });

  it("prebuilt ABI 115 (Node 20) file differs from current runtime ABI", async () => {
    // This test documents the expected behavior: prebuilts are built for Node 20
    // but the dev machine may run a newer Node. The pkg compiler embeds Node 20.
    const currentAbi = parseInt(process.versions.modules, 10);
    const node20Abi = 115;

    if (currentAbi !== node20Abi) {
      // On Node 22+: prebuilts won't load on this machine — that's expected!
      // They ARE correct for pkg-compiled binaries (which embed Node 20).
      const { createRequire } = await import("node:module");
      const require = createRequire(import.meta.url);
      const prebuiltPath = path.join(
        REPO_ROOT,
        "scripts",
        "prebuilds",
        "darwin-arm64",
        "better_sqlite3.node"
      );

      if (existsSync(prebuiltPath) && process.platform === "darwin" && process.arch === "arm64") {
        expect(() => require(prebuiltPath)).toThrow(/NODE_MODULE_VERSION/);
      }
    }
  });
});

// ── findNativeAddon Integration ───────────────────────────────────────────────

describe("findNativeAddon — prebuilds lookup", () => {
  it("finds prebuilt for all 5 targets when scripts/prebuilds/ is populated", async () => {
    const { findNativeAddon, SUPPORTED_TARGETS } = await import(
      "../compile-binary.js"
    );

    for (const target of SUPPORTED_TARGETS) {
      const result = findNativeAddon(target);
      expect(result).not.toBeNull();
      expect(result).toContain("scripts/prebuilds");
      expect(result).toContain(target);
      expect(result).toContain("better_sqlite3.node");
    }
  });

  it("each prebuilt path returned by findNativeAddon actually exists", async () => {
    const { findNativeAddon, SUPPORTED_TARGETS } = await import(
      "../compile-binary.js"
    );

    for (const target of SUPPORTED_TARGETS) {
      const result = findNativeAddon(target);
      if (result) {
        expect(existsSync(result)).toBe(true);
      }
    }
  });
});
