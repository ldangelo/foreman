import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { loadMergeConfig, DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";

describe("loadMergeConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "foreman-config-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns defaults when no config file exists", () => {
    const config = loadMergeConfig(tmpDir);

    expect(config).toEqual(DEFAULT_MERGE_CONFIG);
    expect(config.tier2SafetyCheck.maxDiscardedLines).toBe(20);
    expect(config.tier2SafetyCheck.maxDiscardedPercent).toBe(30);
    expect(config.costControls.maxFileLines).toBe(1000);
    expect(config.costControls.maxSessionBudgetUsd).toBe(5.0);
    expect(config.testAfterMerge).toBe("ai-only");
    expect(config.syntaxCheckers[".ts"]).toBe("tsc --noEmit");
    expect(config.syntaxCheckers[".js"]).toBe("node --check");
  });

  it("returns defaults when file has no mergeQueue key", () => {
    const configDir = path.join(tmpDir, ".foreman");
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(
      path.join(configDir, "config.json"),
      JSON.stringify({ someOtherKey: "value" }),
    );

    const config = loadMergeConfig(tmpDir);

    expect(config).toEqual(DEFAULT_MERGE_CONFIG);
  });

  it("merges partial config with defaults (user overrides some values)", () => {
    const configDir = path.join(tmpDir, ".foreman");
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(
      path.join(configDir, "config.json"),
      JSON.stringify({
        mergeQueue: {
          testAfterMerge: "always",
          costControls: {
            maxSessionBudgetUsd: 10.0,
          },
        },
      }),
    );

    const config = loadMergeConfig(tmpDir);

    // Overridden values
    expect(config.testAfterMerge).toBe("always");
    expect(config.costControls.maxSessionBudgetUsd).toBe(10.0);

    // Defaults preserved
    expect(config.tier2SafetyCheck.maxDiscardedLines).toBe(20);
    expect(config.tier2SafetyCheck.maxDiscardedPercent).toBe(30);
    expect(config.costControls.maxFileLines).toBe(1000);
    expect(config.syntaxCheckers[".ts"]).toBe("tsc --noEmit");
    expect(config.proseDetection[".ts"]).toEqual(
      DEFAULT_MERGE_CONFIG.proseDetection[".ts"],
    );
  });

  it("returns defaults and warns on invalid JSON", () => {
    const configDir = path.join(tmpDir, ".foreman");
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(
      path.join(configDir, "config.json"),
      "{ this is not valid json }}}",
    );

    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    const config = loadMergeConfig(tmpDir);

    expect(config).toEqual(DEFAULT_MERGE_CONFIG);
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining("Failed to parse"),
    );

    warnSpy.mockRestore();
  });

  it("allows full config to override all defaults", () => {
    const fullConfig: MergeQueueConfig = {
      tier2SafetyCheck: {
        maxDiscardedLines: 50,
        maxDiscardedPercent: 60,
      },
      costControls: {
        maxFileLines: 2000,
        maxSessionBudgetUsd: 20.0,
      },
      syntaxCheckers: {
        ".rs": "cargo check",
      },
      proseDetection: {
        ".rs": ["^use\\b", "^fn\\b", "^struct\\b"],
      },
      testAfterMerge: "never",
    };

    const configDir = path.join(tmpDir, ".foreman");
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(
      path.join(configDir, "config.json"),
      JSON.stringify({ mergeQueue: fullConfig }),
    );

    const config = loadMergeConfig(tmpDir);

    expect(config).toEqual(fullConfig);
  });

  it("handles nested partial overrides within tier2SafetyCheck", () => {
    const configDir = path.join(tmpDir, ".foreman");
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(
      path.join(configDir, "config.json"),
      JSON.stringify({
        mergeQueue: {
          tier2SafetyCheck: {
            maxDiscardedLines: 42,
          },
        },
      }),
    );

    const config = loadMergeConfig(tmpDir);

    // Overridden
    expect(config.tier2SafetyCheck.maxDiscardedLines).toBe(42);
    // Default preserved within same nested object
    expect(config.tier2SafetyCheck.maxDiscardedPercent).toBe(30);
    // Other defaults preserved
    expect(config.costControls.maxFileLines).toBe(1000);
    expect(config.testAfterMerge).toBe("ai-only");
  });
});
