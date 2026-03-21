/**
 * TRD-020-TEST: Reproducer Phase Tests
 *
 * Tests for the Reproducer pipeline phase implementation.
 * Covers: reproducerPrompt(), ROLE_CONFIGS reproducer entry, workflow flags,
 * and CANNOT_REPRODUCE verdict detection logic.
 *
 * Note: agent-worker.ts cannot be imported directly in tests (main() runs at import).
 * Tests exercise components exported from roles.ts, workflow-config-loader.ts,
 * and the bundled reproducer.md prompt.
 *
 * Satisfies: REQ-015, AC-015-1 through AC-015-4
 */

import { describe, it, expect } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import { reproducerPrompt, ROLE_CONFIGS } from "../roles.js";
import { DEFAULT_WORKFLOWS, getWorkflow } from "../../lib/workflow-config-loader.js";

// ── reproducerPrompt() tests (AC-015-1) ─────────────────────────────────────

describe("reproducerPrompt() (TRD-020)", () => {
  it("AC-015-1: returns a non-empty string prompt", () => {
    const result = reproducerPrompt("bd-abc1", "Fix login bug", "Users cannot log in");
    expect(typeof result).toBe("string");
    expect(result.length).toBeGreaterThan(100);
  });

  it("AC-015-1: interpolates seedId into prompt", () => {
    const result = reproducerPrompt("bd-xyz9", "Title", "Description");
    expect(result).toContain("bd-xyz9");
  });

  it("AC-015-1: interpolates seedTitle into prompt", () => {
    const result = reproducerPrompt("bd-abc1", "Fix memory leak in parser", "Description");
    expect(result).toContain("Fix memory leak in parser");
  });

  it("AC-015-1: interpolates seedDescription into prompt", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Users see a 500 error when loading dashboard");
    expect(result).toContain("Users see a 500 error when loading dashboard");
  });

  it("AC-015-1: includes REPRODUCER_REPORT.md instructions", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Description");
    expect(result).toContain("REPRODUCER_REPORT.md");
  });

  it("AC-015-2: includes CANNOT_REPRODUCE verdict option", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Description");
    expect(result).toContain("CANNOT_REPRODUCE");
  });

  it("AC-015-3: includes DO NOT modify source files rule", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Description");
    // Should mention read-only / no source modification constraint
    expect(result).toMatch(/DO NOT.*modify|DO NOT.*implement/i);
  });

  it("includes seedComments when provided", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Description", "Extra context here");
    expect(result).toContain("Extra context here");
  });

  it("excludes comments section when seedComments is undefined", () => {
    const withComments = reproducerPrompt("bd-abc1", "Title", "Description", "Some comments");
    const withoutComments = reproducerPrompt("bd-abc1", "Title", "Description");
    // Without comments should be shorter
    expect(withoutComments.length).toBeLessThan(withComments.length);
  });

  it("prompt instructs to send report to REPRODUCER_REPORT.md (AC-015-3)", () => {
    const result = reproducerPrompt("bd-abc1", "Title", "Description");
    // Must write findings to REPRODUCER_REPORT.md
    expect(result).toContain("REPRODUCER_REPORT.md");
  });
});

// ── ROLE_CONFIGS reproducer entry (TRD-020 / AC-015-1) ────────────────────────

describe("ROLE_CONFIGS reproducer entry (TRD-020)", () => {
  it("reproducer entry exists in ROLE_CONFIGS", () => {
    expect(ROLE_CONFIGS).toHaveProperty("reproducer");
  });

  it("reproducer has a model defined", () => {
    const reproducer = ROLE_CONFIGS["reproducer"];
    expect(typeof reproducer.model).toBe("string");
    expect(reproducer.model.length).toBeGreaterThan(0);
  });

  it("reproducer has maxBudgetUsd > 0", () => {
    const reproducer = ROLE_CONFIGS["reproducer"];
    expect(reproducer.maxBudgetUsd).toBeGreaterThan(0);
  });

  it("reproducer reportFile is REPRODUCER_REPORT.md", () => {
    const reproducer = ROLE_CONFIGS["reproducer"];
    expect(reproducer.reportFile).toBe("REPRODUCER_REPORT.md");
  });

  it("reproducer allowedTools includes Read, Write, Bash (reproduce + report writing)", () => {
    const reproducer = ROLE_CONFIGS["reproducer"];
    expect(reproducer.allowedTools).toContain("Read");
    expect(reproducer.allowedTools).toContain("Write");
    expect(reproducer.allowedTools).toContain("Bash");
  });

  it("reproducer role is 'reproducer'", () => {
    expect(ROLE_CONFIGS["reproducer"].role).toBe("reproducer");
  });
});

// ── Workflow flags for reproducer (TRD-020 / AC-015-1) ───────────────────────

describe("Reproducer workflow flags (TRD-020)", () => {
  it("AC-015-1: bug workflow includes reproducer as first phase", () => {
    const phases = DEFAULT_WORKFLOWS["bug"]!;
    expect(phases).toContain("reproducer");
    expect(phases[0]).toBe("reproducer");
  });

  it("AC-015-1: feature workflow does not include reproducer", () => {
    const phases = DEFAULT_WORKFLOWS["feature"]!;
    expect(phases).not.toContain("reproducer");
  });

  it("AC-015-1: chore workflow does not include reproducer", () => {
    const phases = DEFAULT_WORKFLOWS["chore"]!;
    expect(phases).not.toContain("reproducer");
  });

  it("getWorkflow('bug') returns workflow with reproducer first", () => {
    const phases = getWorkflow("bug");
    expect(phases[0]).toBe("reproducer");
    expect(phases).toContain("developer");
    expect(phases).toContain("finalize");
  });

  it("hasReproducerInWorkflow is true for bug seed type", () => {
    const phases = getWorkflow("bug");
    const hasReproducer = phases.includes("reproducer");
    expect(hasReproducer).toBe(true);
  });

  it("hasReproducerInWorkflow is false for feature seed type", () => {
    const phases = getWorkflow("feature");
    const hasReproducer = phases.includes("reproducer");
    expect(hasReproducer).toBe(false);
  });
});

// ── CANNOT_REPRODUCE verdict detection (AC-015-2) ────────────────────────────

describe("CANNOT_REPRODUCE verdict detection (TRD-020 / AC-015-2)", () => {
  /** Mirrors the detection logic in runPipeline() */
  function cannotReproduceVerdictPresent(report: string): boolean {
    return /CANNOT_REPRODUCE/i.test(report);
  }

  it("AC-015-2: detects CANNOT_REPRODUCE verdict in report", () => {
    const report = `# Reproducer Report: Test\n\n## Verdict: CANNOT_REPRODUCE\n\nCould not trigger the bug.`;
    expect(cannotReproduceVerdictPresent(report)).toBe(true);
  });

  it("AC-015-2: does not detect CANNOT_REPRODUCE when verdict is REPRODUCED", () => {
    const report = `# Reproducer Report: Test\n\n## Verdict: REPRODUCED\n\nBug confirmed.`;
    expect(cannotReproduceVerdictPresent(report)).toBe(false);
  });

  it("AC-015-2: detection is case-insensitive", () => {
    const report = `## Verdict: cannot_reproduce\n\nBug not found.`;
    expect(cannotReproduceVerdictPresent(report)).toBe(true);
  });

  it("AC-015-2: returns false for empty report", () => {
    expect(cannotReproduceVerdictPresent("")).toBe(false);
  });

  it("AC-015-2: returns false for report with no verdict", () => {
    const report = `# Report\n\nSome content here without a verdict line.`;
    expect(cannotReproduceVerdictPresent(report)).toBe(false);
  });

  it("AC-015-2: REPRODUCED verdict without CANNOT_REPRODUCE → pipeline continues", () => {
    const report = `# Reproducer Report\n\n## Verdict: REPRODUCED\n\nBug confirmed at line 42.`;
    expect(cannotReproduceVerdictPresent(report)).toBe(false);
    // Pipeline proceeds to Developer
  });
});

// ── Bundled reproducer.md prompt file (TRD-017 / AC-014-3) ───────────────────

describe("Bundled reproducer.md prompt file (TRD-017)", () => {
  const defaultsDir = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    "..", "..", "..", "src", "defaults",
  );

  it("reproducer.md exists in src/defaults/prompts/", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    expect(fs.existsSync(filePath)).toBe(true);
  });

  it("reproducer.md contains {{seedId}} placeholder", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    const content = fs.readFileSync(filePath, "utf-8");
    expect(content).toContain("{{seedId}}");
  });

  it("reproducer.md contains {{seedTitle}} placeholder", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    const content = fs.readFileSync(filePath, "utf-8");
    expect(content).toContain("{{seedTitle}}");
  });

  it("reproducer.md contains {{seedDescription}} placeholder", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    const content = fs.readFileSync(filePath, "utf-8");
    expect(content).toContain("{{seedDescription}}");
  });

  it("reproducer.md contains CANNOT_REPRODUCE verdict option", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    const content = fs.readFileSync(filePath, "utf-8");
    expect(content).toContain("CANNOT_REPRODUCE");
  });

  it("reproducer.md contains REPRODUCER_REPORT.md instruction", () => {
    const filePath = path.join(defaultsDir, "prompts", "reproducer.md");
    const content = fs.readFileSync(filePath, "utf-8");
    expect(content).toContain("REPRODUCER_REPORT.md");
  });
});
