/**
 * Tests for scripts/native-addon-utils.ts
 *
 * These tests verify:
 * - Platform detection and normalisation (win32 → win)
 * - Path resolution for better_sqlite3.node
 * - Copy behaviour including error cases
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import path from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";

// ── detectPlatform ────────────────────────────────────────────────────────────

describe("detectPlatform", () => {
  it("returns platform, arch, and key", async () => {
    const { detectPlatform } = await import("../native-addon-utils.js");
    const info = detectPlatform();
    expect(info).toHaveProperty("platform");
    expect(info).toHaveProperty("arch");
    expect(info).toHaveProperty("key");
    expect(info.key).toBe(`${info.platform}-${info.arch}`);
  });

  it("normalises win32 to win", async () => {
    const originalPlatform = process.platform;

    // Override process.platform
    Object.defineProperty(process, "platform", {
      value: "win32",
      configurable: true,
    });

    // Re-import with cleared module cache by importing fresh
    const { detectPlatform } = await import("../native-addon-utils.js");
    const info = detectPlatform();
    expect(info.platform).toBe("win");
    expect(info.key).toMatch(/^win-/);

    // Restore
    Object.defineProperty(process, "platform", {
      value: originalPlatform,
      configurable: true,
    });
  });

  it("preserves darwin platform as-is", async () => {
    const { detectPlatform } = await import("../native-addon-utils.js");
    const info = detectPlatform();
    // On darwin machines this should remain "darwin"; on linux "linux"
    if (process.platform === "darwin") {
      expect(info.platform).toBe("darwin");
    } else if (process.platform === "linux") {
      expect(info.platform).toBe("linux");
    }
  });
});

// ── getBetterSqlite3NodePath ──────────────────────────────────────────────────

describe("getBetterSqlite3NodePath", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(tmpdir(), `foreman-test-${randomUUID()}`);
    mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns null when neither location exists", async () => {
    const { getBetterSqlite3NodePath } = await import("../native-addon-utils.js");
    const result = getBetterSqlite3NodePath(tmpDir);
    expect(result).toBeNull();
  });

  it("finds .node in build/Release/ (primary path)", async () => {
    const { getBetterSqlite3NodePath } = await import("../native-addon-utils.js");

    const releaseDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "build",
      "Release"
    );
    mkdirSync(releaseDir, { recursive: true });
    const nodePath = path.join(releaseDir, "better_sqlite3.node");
    writeFileSync(nodePath, "fake-binary");

    const result = getBetterSqlite3NodePath(tmpDir);
    expect(result).toBe(nodePath);
  });

  it("finds .node in prebuilds/ fallback path", async () => {
    const { getBetterSqlite3NodePath, detectPlatform } = await import(
      "../native-addon-utils.js"
    );

    const { key } = detectPlatform();
    const prebuildsDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "prebuilds",
      key
    );
    mkdirSync(prebuildsDir, { recursive: true });
    const nodePath = path.join(prebuildsDir, "node.napi.node");
    writeFileSync(nodePath, "fake-binary");

    const result = getBetterSqlite3NodePath(tmpDir);
    expect(result).toBe(nodePath);
  });

  it("prefers primary path over fallback when both exist", async () => {
    const { getBetterSqlite3NodePath, detectPlatform } = await import(
      "../native-addon-utils.js"
    );

    // Create primary
    const releaseDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "build",
      "Release"
    );
    mkdirSync(releaseDir, { recursive: true });
    const primaryPath = path.join(releaseDir, "better_sqlite3.node");
    writeFileSync(primaryPath, "primary-binary");

    // Create fallback
    const { key } = detectPlatform();
    const prebuildsDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "prebuilds",
      key
    );
    mkdirSync(prebuildsDir, { recursive: true });
    writeFileSync(path.join(prebuildsDir, "node.napi.node"), "fallback-binary");

    const result = getBetterSqlite3NodePath(tmpDir);
    expect(result).toBe(primaryPath);
  });
});

// ── copyNativeAddon ───────────────────────────────────────────────────────────

describe("copyNativeAddon", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(tmpdir(), `foreman-test-${randomUUID()}`);
    mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("throws when .node binary is not found", async () => {
    const { copyNativeAddon } = await import("../native-addon-utils.js");
    const outputDir = path.join(tmpDir, "dist");
    expect(() => copyNativeAddon(tmpDir, outputDir)).toThrow(
      /Could not find better_sqlite3\.node/
    );
  });

  it("copies .node to outputDir/better_sqlite3.node", async () => {
    const { copyNativeAddon } = await import("../native-addon-utils.js");

    // Create a fake .node in the expected location
    const releaseDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "build",
      "Release"
    );
    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(path.join(releaseDir, "better_sqlite3.node"), "fake-binary-content");

    const outputDir = path.join(tmpDir, "dist");
    copyNativeAddon(tmpDir, outputDir);

    const dest = path.join(outputDir, "better_sqlite3.node");
    expect(existsSync(dest)).toBe(true);
  });

  it("creates outputDir if it does not exist", async () => {
    const { copyNativeAddon } = await import("../native-addon-utils.js");

    const releaseDir = path.join(
      tmpDir,
      "node_modules",
      "better-sqlite3",
      "build",
      "Release"
    );
    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(path.join(releaseDir, "better_sqlite3.node"), "fake");

    const outputDir = path.join(tmpDir, "deeply", "nested", "dist");
    // Should not throw even though outputDir doesn't exist yet
    expect(() => copyNativeAddon(tmpDir, outputDir)).not.toThrow();
    expect(existsSync(outputDir)).toBe(true);
  });

  it("copies the actual better_sqlite3.node from the real node_modules", async () => {
    // This test verifies the real addon is accessible — it's an integration
    // smoke test that proves the copy step works end-to-end on this machine.
    const { copyNativeAddon } = await import("../native-addon-utils.js");

    // Use the actual repo root (two levels up from scripts/__tests__)
    const repoRoot = path.resolve(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      ".."
    );

    const outputDir = path.join(tmpDir, "dist");
    copyNativeAddon(repoRoot, outputDir);

    const dest = path.join(outputDir, "better_sqlite3.node");
    expect(existsSync(dest)).toBe(true);

    // Verify the copied file is non-empty (a real binary, not a stub)
    const { statSync } = await import("node:fs");
    expect(statSync(dest).size).toBeGreaterThan(0);
  });
});
