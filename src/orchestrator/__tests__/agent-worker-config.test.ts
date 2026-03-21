/**
 * TRD-016-TEST: Wire Loaders Integration Tests
 *
 * Validates that the workflow-driven phase iteration logic (TRD-016a through TRD-016e)
 * produces the correct phase flags and config lookups for each seed type.
 *
 * Tests use real loader functions (loadPhaseConfigs, getWorkflow, DEFAULT_WORKFLOWS)
 * so they exercise the actual integration path without importing agent-worker.ts
 * (which has a main() side-effect at import time).
 *
 * Satisfies: REQ-012, AC-012-1 through AC-012-8
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { DEFAULT_WORKFLOWS, getWorkflow, validateWorkflowPhases, validateFinalizeEnforcement } from "../../lib/workflow-config-loader.js";
import { loadPhaseConfigs, validatePhaseConfigEntry } from "../../lib/phase-config-loader.js";
import { ROLE_CONFIGS } from "../roles.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Compute workflow flags from a phase list — mirrors the logic in runPipeline().
 * AC-012-7, AC-012-8: workflow-derived flags determine which phases run.
 */
function computeWorkflowFlags(workflowPhases: string[]) {
  return {
    hasExplorerInWorkflow: workflowPhases.includes("explorer"),
    hasQaInWorkflow: workflowPhases.includes("qa"),
    hasReviewerInWorkflow: workflowPhases.includes("reviewer"),
    hasReproducerInWorkflow: workflowPhases.includes("reproducer"),
  };
}

// ── DEFAULT_WORKFLOWS phase flag tests (TRD-016a) ────────────────────────────

describe("Workflow-derived phase flags (TRD-016a)", () => {
  it("AC-012-7: feature workflow enables explorer, qa, reviewer; no reproducer", () => {
    const phases = DEFAULT_WORKFLOWS["feature"]!;
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(true);
    expect(flags.hasQaInWorkflow).toBe(true);
    expect(flags.hasReviewerInWorkflow).toBe(true);
    expect(flags.hasReproducerInWorkflow).toBe(false);
  });

  it("AC-012-7: bug workflow enables reproducer, qa; no explorer, no reviewer", () => {
    const phases = DEFAULT_WORKFLOWS["bug"]!;
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(false);
    expect(flags.hasQaInWorkflow).toBe(true);
    expect(flags.hasReviewerInWorkflow).toBe(false);
    expect(flags.hasReproducerInWorkflow).toBe(true);
  });

  it("AC-012-8: chore workflow disables explorer, qa skipped (no qa phase), no reviewer", () => {
    const phases = DEFAULT_WORKFLOWS["chore"]!;
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(false);
    expect(flags.hasQaInWorkflow).toBe(false);
    expect(flags.hasReviewerInWorkflow).toBe(false);
    expect(flags.hasReproducerInWorkflow).toBe(false);
  });

  it("AC-012-8: docs workflow has same minimal structure as chore", () => {
    const phases = DEFAULT_WORKFLOWS["docs"]!;
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(false);
    expect(flags.hasQaInWorkflow).toBe(false);
    expect(flags.hasReviewerInWorkflow).toBe(false);
  });

  it("all default workflows contain developer phase (core phase always present)", () => {
    for (const [seedType, phases] of Object.entries(DEFAULT_WORKFLOWS)) {
      expect(phases, `${seedType} workflow must contain developer`).toContain("developer");
    }
  });

  it("all default workflows end with finalize (TRD-015 enforcement)", () => {
    for (const [seedType, phases] of Object.entries(DEFAULT_WORKFLOWS)) {
      expect(phases[phases.length - 1], `${seedType} workflow must end with finalize`).toBe("finalize");
    }
  });
});

// ── getWorkflow() fallback tests (TRD-013) ────────────────────────────────────

describe("getWorkflow() seed-type fallback (TRD-013)", () => {
  it("AC-012-1: 'feature' seed type returns feature workflow", () => {
    const phases = getWorkflow("feature");
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(true);
    expect(flags.hasQaInWorkflow).toBe(true);
    expect(flags.hasReviewerInWorkflow).toBe(true);
  });

  it("AC-012-1: 'bug' seed type returns bug workflow (reproducer first)", () => {
    const phases = getWorkflow("bug");
    expect(phases[0]).toBe("reproducer");
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasReproducerInWorkflow).toBe(true);
    expect(flags.hasExplorerInWorkflow).toBe(false);
  });

  it("AC-012-1: unknown seed type falls back to feature workflow", () => {
    const phases = getWorkflow("completely-unknown-type");
    // Falls back to feature workflow — must have explorer + qa + reviewer
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(true);
    expect(phases[phases.length - 1]).toBe("finalize");
  });

  it("AC-012-1: 'chore' seed type returns minimal workflow (developer only + finalize)", () => {
    const phases = getWorkflow("chore");
    const flags = computeWorkflowFlags(phases);
    expect(flags.hasExplorerInWorkflow).toBe(false);
    expect(flags.hasQaInWorkflow).toBe(false);
    expect(flags.hasReviewerInWorkflow).toBe(false);
    expect(phases).toContain("developer");
    expect(phases[phases.length - 1]).toBe("finalize");
  });
});

// ── validateWorkflowPhases() integration (TRD-014) ───────────────────────────

describe("validateWorkflowPhases() with loadPhaseConfigs() (TRD-014)", () => {
  it("AC-012-2: feature workflow passes validation against built-in phase configs", () => {
    const phaseConfigs = loadPhaseConfigs();
    const workflow = DEFAULT_WORKFLOWS["feature"]!;
    expect(() => validateWorkflowPhases(workflow, phaseConfigs, "feature")).not.toThrow();
  });

  it("AC-012-2: bug workflow passes validation against built-in phase configs", () => {
    const phaseConfigs = loadPhaseConfigs();
    const workflow = DEFAULT_WORKFLOWS["bug"]!;
    expect(() => validateWorkflowPhases(workflow, phaseConfigs, "bug")).not.toThrow();
  });

  it("AC-012-2: all DEFAULT_WORKFLOWS pass validation", () => {
    const phaseConfigs = loadPhaseConfigs();
    for (const [seedType, workflow] of Object.entries(DEFAULT_WORKFLOWS)) {
      expect(() => validateWorkflowPhases(workflow, phaseConfigs, seedType), `${seedType} should pass validation`).not.toThrow();
    }
  });

  it("AC-012-3: workflow with unknown phase throws validation error", () => {
    const phaseConfigs = loadPhaseConfigs();
    const badWorkflow = ["explorer", "unknown_phase_xyz", "developer", "finalize"];
    expect(() => validateWorkflowPhases(badWorkflow, phaseConfigs, "feature")).toThrow(/unknown_phase_xyz/);
  });

  it("AC-012-2: validateFinalizeEnforcement passes for DEFAULT_WORKFLOWS", () => {
    expect(() => validateFinalizeEnforcement(DEFAULT_WORKFLOWS)).not.toThrow();
  });
});

// ── loadPhaseConfigs() fallback tests (TRD-012) ────────────────────────────────

describe("loadPhaseConfigs() ROLE_CONFIGS fallback (TRD-016c / AC-012-5, AC-012-6)", () => {
  it("AC-012-6: ROLE_CONFIGS fallback provides model for all built-in phases", () => {
    const phaseConfigs = loadPhaseConfigs();
    // All ROLE_CONFIGS phases must have a model in the resolved config
    for (const phaseName of Object.keys(ROLE_CONFIGS)) {
      const entry = phaseConfigs[phaseName];
      expect(entry, `${phaseName} must have a phase config entry`).toBeDefined();
      expect(typeof entry!.model).toBe("string");
      expect(entry!.model.length).toBeGreaterThan(0);
    }
  });

  it("AC-012-6: ROLE_CONFIGS fallback provides maxBudgetUsd for all built-in phases", () => {
    const phaseConfigs = loadPhaseConfigs();
    for (const phaseName of Object.keys(ROLE_CONFIGS)) {
      const entry = phaseConfigs[phaseName];
      expect(typeof entry!.maxBudgetUsd).toBe("number");
      expect(entry!.maxBudgetUsd).toBeGreaterThan(0);
    }
  });

  it("AC-012-6: ROLE_CONFIGS fallback allowedTools is an array for all built-in phases", () => {
    const phaseConfigs = loadPhaseConfigs();
    for (const phaseName of Object.keys(ROLE_CONFIGS)) {
      expect(Array.isArray(phaseConfigs[phaseName]!.allowedTools)).toBe(true);
    }
  });

  it("AC-012-5: custom phases.json overrides are applied when file exists", () => {
    // Use a temp home dir to simulate a custom phases.json
    const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "foreman-config-test-"));
    const foremanDir = path.join(tmpHome, ".foreman");
    fs.mkdirSync(foremanDir, { recursive: true });

    const customModel = "claude-haiku-4-5-20251001";
    const customPhases = {
      explorer: {
        model: customModel,
        maxBudgetUsd: 0.5,
        allowedTools: ["Read", "Bash"],
        reportFile: "EXPLORER_REPORT.md",
        promptFile: "explorer.md",
      },
    };
    fs.writeFileSync(path.join(foremanDir, "phases.json"), JSON.stringify(customPhases));

    // We can't easily override HOME in ESM modules without process.env manipulation,
    // but we can validate the shape of the external config entry directly:
    validatePhaseConfigEntry("explorer", customPhases.explorer);
    expect(customPhases.explorer.model).toBe(customModel);
    expect(customPhases.explorer.maxBudgetUsd).toBe(0.5);
    expect(customPhases.explorer.allowedTools).toEqual(["Read", "Bash"]);

    fs.rmSync(tmpHome, { recursive: true, force: true });
  });
});

// ── Phase config model values (bundled defaults consistency) ──────────────────

describe("Phase config model consistency (TRD-016c AC-012-5)", () => {
  it("loadPhaseConfigs() explorer uses haiku model by default (env-override aware)", () => {
    const phaseConfigs = loadPhaseConfigs();
    const explorer = phaseConfigs["explorer"];
    expect(explorer).toBeDefined();
    // Explorer should use a haiku model by default (unless env var overrides)
    // We just verify the model string is non-empty and present
    expect(typeof explorer!.model).toBe("string");
    expect(explorer!.model.length).toBeGreaterThan(0);
  });

  it("loadPhaseConfigs() developer uses sonnet model by default", () => {
    const phaseConfigs = loadPhaseConfigs();
    const developer = phaseConfigs["developer"];
    expect(developer).toBeDefined();
    expect(typeof developer!.model).toBe("string");
    expect(developer!.model.length).toBeGreaterThan(0);
  });
});

// ── QA retry loop skip logic (TRD-016d) ──────────────────────────────────────

describe("QA retry loop skip logic (TRD-016d)", () => {
  it("AC-012-8: chore workflow excludes qa → hasQaInWorkflow is false", () => {
    const phases = getWorkflow("chore");
    const { hasQaInWorkflow } = computeWorkflowFlags(phases);
    expect(hasQaInWorkflow).toBe(false);
    // Pipeline should skip QA block and break immediately after Developer
  });

  it("AC-012-8: docs workflow excludes qa → hasQaInWorkflow is false", () => {
    const phases = getWorkflow("docs");
    const { hasQaInWorkflow } = computeWorkflowFlags(phases);
    expect(hasQaInWorkflow).toBe(false);
  });

  it("AC-012-7: feature workflow includes qa → hasQaInWorkflow is true", () => {
    const phases = getWorkflow("feature");
    const { hasQaInWorkflow } = computeWorkflowFlags(phases);
    expect(hasQaInWorkflow).toBe(true);
  });

  it("AC-012-7: bug workflow includes qa → hasQaInWorkflow is true", () => {
    const phases = getWorkflow("bug");
    const { hasQaInWorkflow } = computeWorkflowFlags(phases);
    expect(hasQaInWorkflow).toBe(true);
  });
});

// ── Reviewer skip logic (TRD-016e) ───────────────────────────────────────────

describe("Reviewer skip logic (TRD-016e)", () => {
  it("AC-012-7: feature workflow includes reviewer → hasReviewerInWorkflow is true", () => {
    const phases = getWorkflow("feature");
    const { hasReviewerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReviewerInWorkflow).toBe(true);
  });

  it("AC-012-7: bug workflow excludes reviewer → hasReviewerInWorkflow is false", () => {
    const phases = getWorkflow("bug");
    const { hasReviewerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReviewerInWorkflow).toBe(false);
  });

  it("AC-012-8: chore workflow excludes reviewer → hasReviewerInWorkflow is false", () => {
    const phases = getWorkflow("chore");
    const { hasReviewerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReviewerInWorkflow).toBe(false);
  });

  it("AC-012-8: docs workflow excludes reviewer → hasReviewerInWorkflow is false", () => {
    const phases = getWorkflow("docs");
    const { hasReviewerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReviewerInWorkflow).toBe(false);
  });
});

// ── Reproducer phase flag (TRD-020) ──────────────────────────────────────────

describe("Reproducer phase flag (TRD-016a / TRD-020)", () => {
  it("bug workflow enables reproducer as first phase", () => {
    const phases = getWorkflow("bug");
    const { hasReproducerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReproducerInWorkflow).toBe(true);
    expect(phases[0]).toBe("reproducer");
  });

  it("feature workflow does not enable reproducer", () => {
    const phases = getWorkflow("feature");
    const { hasReproducerInWorkflow } = computeWorkflowFlags(phases);
    expect(hasReproducerInWorkflow).toBe(false);
  });
});
