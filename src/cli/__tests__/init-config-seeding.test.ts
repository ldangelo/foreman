/**
 * TRD-019-TEST: foreman init Config Seeding Tests
 *
 * Tests for initDefaultConfigs() — the function that seeds ~/.foreman/ with
 * bundled default configuration files on first `foreman init`.
 *
 * Uses real temp directories and injectable opts to avoid ESM module mocking.
 * Satisfies: REQ-013, AC-013-1 through AC-013-5
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { initDefaultConfigs, type InitDefaultConfigsOpts } from "../commands/init.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Create a temp directory and return its path. */
function makeTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "foreman-init-seed-test-"));
}

/** List all files under a directory recursively, relative to the root. */
function listFiles(dir: string): string[] {
  const results: string[] = [];
  if (!fs.existsSync(dir)) return results;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const rel = entry.name;
    if (entry.isDirectory()) {
      const sub = listFiles(path.join(dir, rel));
      results.push(...sub.map((f) => path.join(rel, f)));
    } else {
      results.push(rel);
    }
  }
  return results.sort();
}

/** Resolve the real bundled defaults directory from the source tree. */
function realDefaultsDir(): string {
  // This test runs from src/cli/__tests__/, so:
  // go up 3 levels → project root → src/defaults/
  const thisDir = path.dirname(new URL(import.meta.url).pathname);
  return path.resolve(thisDir, "..", "..", "defaults");
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("initDefaultConfigs() (TRD-019)", () => {
  let tmpForemanDir: string;
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = makeTempDir();
    tmpForemanDir = path.join(tmpRoot, ".foreman");
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  // ── AC-013-1: Fresh init creates all config files ──────────────────────────

  it("AC-013-1: fresh init creates phases.json in ~/.foreman/", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    expect(fs.existsSync(path.join(tmpForemanDir, "phases.json"))).toBe(true);
  });

  it("AC-013-1: fresh init creates workflows.json in ~/.foreman/", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    expect(fs.existsSync(path.join(tmpForemanDir, "workflows.json"))).toBe(true);
  });

  it("AC-013-1: fresh init creates ~/.foreman/prompts/ directory", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    expect(fs.existsSync(path.join(tmpForemanDir, "prompts"))).toBe(true);
  });

  it("AC-013-1: fresh init copies all five prompt files", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const promptsDir = path.join(tmpForemanDir, "prompts");
    const expectedFiles = ["developer.md", "explorer.md", "qa.md", "reproducer.md", "reviewer.md"];
    for (const filename of expectedFiles) {
      expect(
        fs.existsSync(path.join(promptsDir, filename)),
        `${filename} should be copied`,
      ).toBe(true);
    }
  });

  it("AC-013-1: copied phases.json contains valid JSON", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const content = fs.readFileSync(path.join(tmpForemanDir, "phases.json"), "utf-8");
    expect(() => JSON.parse(content)).not.toThrow();
    const phases = JSON.parse(content) as Record<string, unknown>;
    expect(phases).toHaveProperty("explorer");
    expect(phases).toHaveProperty("developer");
    expect(phases).toHaveProperty("qa");
    expect(phases).toHaveProperty("reviewer");
  });

  it("AC-013-1: copied workflows.json contains valid JSON with expected workflows", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const content = fs.readFileSync(path.join(tmpForemanDir, "workflows.json"), "utf-8");
    expect(() => JSON.parse(content)).not.toThrow();
    const workflows = JSON.parse(content) as Record<string, string[]>;
    expect(workflows).toHaveProperty("feature");
    expect(workflows).toHaveProperty("bug");
    expect(workflows).toHaveProperty("chore");
    expect(workflows).toHaveProperty("docs");
  });

  // ── AC-013-2: Re-init does not overwrite existing files ────────────────────

  it("AC-013-2: existing phases.json is not overwritten on re-init", () => {
    // Write a custom phases.json
    fs.mkdirSync(tmpForemanDir, { recursive: true });
    const customContent = JSON.stringify({ custom: true });
    fs.writeFileSync(path.join(tmpForemanDir, "phases.json"), customContent, "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const content = fs.readFileSync(path.join(tmpForemanDir, "phases.json"), "utf-8");
    expect(content).toBe(customContent); // unchanged
  });

  it("AC-013-2: existing workflows.json is not overwritten on re-init", () => {
    fs.mkdirSync(tmpForemanDir, { recursive: true });
    const customContent = JSON.stringify({ custom: true });
    fs.writeFileSync(path.join(tmpForemanDir, "workflows.json"), customContent, "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const content = fs.readFileSync(path.join(tmpForemanDir, "workflows.json"), "utf-8");
    expect(content).toBe(customContent); // unchanged
  });

  it("AC-013-2: existing prompt file is not overwritten on re-init", () => {
    fs.mkdirSync(path.join(tmpForemanDir, "prompts"), { recursive: true });
    const customContent = "# My custom developer prompt";
    fs.writeFileSync(path.join(tmpForemanDir, "prompts", "developer.md"), customContent, "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const content = fs.readFileSync(path.join(tmpForemanDir, "prompts", "developer.md"), "utf-8");
    expect(content).toBe(customContent); // unchanged
  });

  // ── AC-013-3: Partial init creates only missing files ─────────────────────

  it("AC-013-3: partial init only creates missing prompt files", () => {
    // Pre-create some prompts but not others
    fs.mkdirSync(path.join(tmpForemanDir, "prompts"), { recursive: true });
    const customExplorer = "# My custom explorer";
    fs.writeFileSync(path.join(tmpForemanDir, "prompts", "explorer.md"), customExplorer, "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    // explorer.md should be unchanged
    const explorerContent = fs.readFileSync(path.join(tmpForemanDir, "prompts", "explorer.md"), "utf-8");
    expect(explorerContent).toBe(customExplorer);

    // developer.md should be newly created
    expect(fs.existsSync(path.join(tmpForemanDir, "prompts", "developer.md"))).toBe(true);
    const developerContent = fs.readFileSync(path.join(tmpForemanDir, "prompts", "developer.md"), "utf-8");
    expect(developerContent.length).toBeGreaterThan(0);
  });

  it("AC-013-3: partial init only creates missing JSON files", () => {
    // Pre-create phases.json but not workflows.json
    fs.mkdirSync(tmpForemanDir, { recursive: true });
    const customPhases = JSON.stringify({ custom: true });
    fs.writeFileSync(path.join(tmpForemanDir, "phases.json"), customPhases, "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    // phases.json unchanged
    expect(fs.readFileSync(path.join(tmpForemanDir, "phases.json"), "utf-8")).toBe(customPhases);

    // workflows.json created
    expect(fs.existsSync(path.join(tmpForemanDir, "workflows.json"))).toBe(true);
  });

  // ── AC-013-4: Confirmation messages are printed ────────────────────────────

  it("AC-013-4: prints confirmation message when phases.json is created", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const calls = (console.log as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]));
    const hasConfirmation = calls.some((msg) => msg.includes("phases.json") && msg.includes("written"));
    expect(hasConfirmation).toBe(true);
  });

  it("AC-013-4: prints skip message when phases.json already exists", () => {
    fs.mkdirSync(tmpForemanDir, { recursive: true });
    fs.writeFileSync(path.join(tmpForemanDir, "phases.json"), "{}", "utf-8");

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const calls = (console.log as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]));
    const hasSkip = calls.some((msg) => msg.includes("phases.json") && msg.includes("skipping"));
    expect(hasSkip).toBe(true);
  });

  it("AC-013-4: prints confirmation message when prompt files are created", () => {
    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    const calls = (console.log as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]));
    const hasDeveloperMsg = calls.some((msg) => msg.includes("developer.md") && msg.includes("written"));
    expect(hasDeveloperMsg).toBe(true);
  });

  // ── AC-013-5: Errors are non-fatal ────────────────────────────────────────

  it("AC-013-5: copyFileSync failure is non-fatal (warns but does not throw)", () => {
    const failingCopy = (_src: string, _dest: string): void => {
      throw new Error("Simulated copy failure");
    };

    // Should not throw even when all copies fail
    expect(() =>
      initDefaultConfigs({
        foremanHomeDir: tmpForemanDir,
        defaultsDir: realDefaultsDir(),
        copyFileSyncFn: failingCopy,
      }),
    ).not.toThrow();

    // Should have printed warning messages
    const warnCalls = (console.warn as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]));
    expect(warnCalls.some((msg) => msg.includes("non-fatal"))).toBe(true);
  });

  it("AC-013-5: readdirSync failure on prompts dir is non-fatal (warns but does not throw)", () => {
    const failingReaddir = (_p: string): string[] => {
      throw new Error("Simulated readdir failure");
    };

    expect(() =>
      initDefaultConfigs({
        foremanHomeDir: tmpForemanDir,
        defaultsDir: realDefaultsDir(),
        readdirSyncFn: failingReaddir,
      }),
    ).not.toThrow();

    const warnCalls = (console.warn as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]));
    expect(warnCalls.some((msg) => msg.includes("non-fatal"))).toBe(true);
  });

  // ── Injectable opts verification ────────────────────────────────────────────

  it("injectable checkExists controls which files are considered present", () => {
    // Simulate all files already exist (checkExists always returns true)
    const alwaysExists = (_p: string): boolean => true;
    const copyCalls: string[] = [];

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
      checkExists: alwaysExists,
      copyFileSyncFn: (src, dest) => { copyCalls.push(dest); },
      mkdirSyncFn: () => undefined,
      readdirSyncFn: (_p) => ["developer.md", "explorer.md"],
    });

    // copyFileSync should never be called since everything "exists"
    expect(copyCalls).toHaveLength(0);
  });

  it("creates ~/.foreman/ directory if it does not exist", () => {
    // tmpForemanDir does not exist yet — initDefaultConfigs should create it
    expect(fs.existsSync(tmpForemanDir)).toBe(false);

    initDefaultConfigs({
      foremanHomeDir: tmpForemanDir,
      defaultsDir: realDefaultsDir(),
    });

    expect(fs.existsSync(tmpForemanDir)).toBe(true);
  });
});
